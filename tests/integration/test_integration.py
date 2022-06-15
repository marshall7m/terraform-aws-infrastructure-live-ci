import pytest
import os
import logging
import json
import time
from datetime import datetime
import github
import git
import timeout_decorator
import random
import string
import re
from pytest_dependency import depends
import aurora_data_api
import boto3
from pprint import pformat
import requests
from tests.integration import utils

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class Integration:
    executions = []

    @pytest.fixture(scope="class")
    def case_param(self, request):
        """Class case fixture used to determine the actions within the CI flow and the expected test assertions"""
        return request.cls.case

    @pytest.fixture(scope="module")
    def tf_destroy_commit_ids(self, mut_output):
        """Creates a list of commit Ids to be used for the source version of the teardown Terragrunt destroy builds"""
        commit_ids = [mut_output["base_branch"]]

        def _add(id=None):
            if id:
                commit_ids.append(id)
            return commit_ids

        yield _add

    @pytest.fixture(scope="class", autouse=True)
    def pr(
        self,
        request,
        repo,
        case_param,
        git_repo,
        merge_pr,
        mut_output,
        tmp_path_factory,
        tf_destroy_commit_ids,
    ):
        """Creates the PR used testing the CI flow. Current implementation creates all PR changes within one commit."""
        if "revert_ref" not in case_param:
            base_commit = repo.get_branch(mut_output["base_branch"])
            head_ref = repo.create_git_ref(
                ref="refs/heads/" + case_param["head_ref"], sha=base_commit.commit.sha
            )
            elements = []
            for dir, cfg in case_param["executions"].items():
                if "pr_files_content" in cfg:
                    for content in cfg["pr_files_content"]:
                        filepath = (
                            dir
                            + "/"
                            + "".join(
                                random.choice(string.ascii_lowercase) for _ in range(8)
                            )
                            + ".tf"
                        )
                        log.debug(f"Creating file: {filepath}")
                        blob = repo.create_git_blob(content, "utf-8")
                        elements.append(
                            github.InputGitTreeElement(
                                path=filepath, mode="100644", type="blob", sha=blob.sha
                            )
                        )

            head_sha = repo.get_branch(case_param["head_ref"]).commit.sha
            base_tree = repo.get_git_tree(sha=head_sha)
            tree = repo.create_git_tree(elements, base_tree)
            parent = repo.get_git_commit(sha=head_sha)
            commit_id = repo.create_git_commit("Case PR changes", tree, [parent]).sha
            head_ref.edit(sha=commit_id)

            log.info("Creating PR")
            pr = repo.create_pull(
                title=f"test-{case_param['head_ref']}",
                body=f"test PR class: {request.cls.__name__}",
                base=mut_output["base_branch"],
                head=case_param["head_ref"],
            )
            log.debug(f"PR #{pr.number}")
            log.debug(f"Head ref commit: {commit_id}")
            log.debug(f"PR commits: {pr.commits}")

            if case_param.get("destroy_tf_resources_with_pr", False):
                # set attribute if PR contains new Terraform provider blocks that require credentials so teardown
                # Terragrunt destroy builds will have the provider blocks needed to destroy the provider resources
                tf_destroy_commit_ids(commit_id)

            yield {
                "number": pr.number,
                "head_commit_id": commit_id,
                "base_ref": mut_output["base_branch"],
                "head_ref": case_param["head_ref"],
            }

        else:
            log.info(
                f'Creating PR to revert changes from PR named: {case_param["revert_ref"]}'
            )
            dir = str(tmp_path_factory.mktemp("scenario-repo-revert"))

            log.info(f'Creating revert branch: {case_param["head_ref"]}')
            base_commit = repo.get_branch(mut_output["base_branch"])
            head_ref = repo.create_git_ref(
                ref="refs/heads/" + case_param["head_ref"], sha=base_commit.commit.sha
            )

            git_repo = git.Repo.clone_from(
                f'https://oauth2:{os.environ["TF_VAR_testing_integration_github_token"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git',
                dir,
                branch=case_param["head_ref"],
            )

            merge_commit = merge_pr()
            log.debug(f"Merged Commits: {merge_commit}")
            log.debug(
                f'Reverting merge commit: {merge_commit[case_param["revert_ref"]].sha}'
            )
            git_repo.git.revert(
                "-m",
                "1",
                "--no-commit",
                str(merge_commit[case_param["revert_ref"]].sha),
            )
            git_repo.git.commit("-m", "Revert PR changes within PR case")
            git_repo.git.push("origin")

            log.debug("Creating PR")
            pr = repo.create_pull(
                title=f'Revert {case_param["revert_ref"]}',
                body="Rollback PR",
                base=mut_output["base_branch"],
                head=case_param["head_ref"],
            )

            yield {
                "number": pr.number,
                "head_commit_id": git_repo.head.object.hexsha,
                "base_ref": mut_output["base_branch"],
                "head_ref": case_param["head_ref"],
            }

        log.info(f"Removing PR head ref branch: {case_param['head_ref']}")
        head_ref.delete()

        log.info(f"Closing PR: #{pr.number}")
        try:
            pr.edit(state="closed")
        except Exception:
            log.info("PR is merged or already closed")

    @pytest.fixture(scope="module")
    def destroy_scenario_tf_resources(self, mut_output, tf_destroy_commit_ids):
        """
        Starts a terra_run build for each AWS account and runs terragrunt run-all destroy
        within each account-level root directory
        """
        yield None

        cb = boto3.client("codebuild")

        log.info("Destroying Terraform provisioned resources from test repository")

        with aurora_data_api.connect(
            aurora_cluster_arn=mut_output["metadb_arn"],
            secret_arn=mut_output["metadb_secret_manager_ci_arn"],
            database=mut_output["metadb_name"],
            # recommended for DDL statements
            continue_after_timeout=True,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                SELECT account_name, account_path, deploy_role_arn
                FROM account_dim
                """
                )

                results = cur.fetchall()
                columns = cur.description

            accounts = []
            for result in results:
                record = {}
                for i, col in enumerate(columns):
                    record[col.name] = result[i]
                accounts.append(record)

        log.debug(f"Accounts:\n{pformat(accounts)}")
        log.info("Starting account-level terraform destroy builds")
        # reversed so newer commits are destroyed first
        for source_version in reversed(tf_destroy_commit_ids()):
            ids = []
            log.debug(f"Source version: {source_version}")
            for account in accounts:
                log.debug(f'Account Name: {account["account_name"]}')
                response = cb.start_build(
                    projectName=mut_output["codebuild_terra_run_name"],
                    environmentVariablesOverride=[
                        {
                            "name": "TG_COMMAND",
                            "type": "PLAINTEXT",
                            "value": f'terragrunt run-all destroy --terragrunt-working-dir {account["account_path"]} --terragrunt-iam-role {account["deploy_role_arn"]} -auto-approve',
                        }
                    ],
                    sourceVersion=source_version,
                )

                ids.append(response["build"]["id"])

            log.info("Waiting on destroy builds to finish")
            statuses = utils.get_build_finished_status(
                mut_output["codebuild_terra_run_name"], ids=ids
            )

            log.info(f"Finished Statuses:\n{statuses}")

    @timeout_decorator.timeout(30)
    @pytest.mark.dependency()
    def test_merge_lock_pr_status(self, repo, mut_output, pr):
        """Assert PR's head commit ID has a successful merge lock status"""
        wait = 3
        merge_lock_status = None
        while merge_lock_status in [None, "pending"]:
            log.debug(f"Waiting {wait} seconds")
            time.sleep(wait)
            try:
                merge_lock_status = [
                    status
                    for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                    if status.context == mut_output["merge_lock_status_check_name"]
                ][0]
            except IndexError:
                merge_lock_status = None

        log.info("Assert PR head commit status is successful")
        assert merge_lock_status.state == "success"

    @timeout_decorator.timeout(300)
    @pytest.mark.dependency()
    def test_pr_plan_codebuild(self, mut_output, pr, case_param):
        """Assert PR plan codebuild status matches it's expected status"""

        log.info("Giving build time to start")
        time.sleep(5)

        status = utils.get_build_finished_status(
            mut_output["codebuild_pr_plan_name"],
            filters={"sourceVersion": f'pr/{pr["number"]}'},
        )[0]

        if case_param.get("expect_failed_pr_plan", False):
            log.info("Assert build failed")
            assert status == "FAILED"
        else:
            log.info("Assert build succeeded")
            assert status == "SUCCEEDED"

    @timeout_decorator.timeout(30)
    @pytest.mark.dependency()
    def test_pr_merge(self, request, mut_output, case_param, merge_pr, pr, repo):
        """
        Ensures that the PR status checks before merging are complete and then
        merges the PR
        """
        depends(request, [f"{request.cls.__name__}::test_merge_lock_pr_status"])
        depends(request, [f"{request.cls.__name__}::test_pr_plan_codebuild"])

        log.info("Ensure all status checks are completed")
        branch = repo.get_branch(branch=mut_output["base_branch"])
        status_checks = branch.get_required_status_checks().contexts
        log.debug(f"Status Checks Required: {status_checks}")
        log.debug(
            f"Branch protection enforced for admins: {branch.get_protection().enforce_admins}"
        )

        statuses = repo.get_commit(pr["head_commit_id"]).get_statuses()
        while statuses.totalCount != 3:
            time.sleep(3)
            statuses = repo.get_commit(pr["head_commit_id"]).get_statuses()
            log.debug(f"Count: {statuses.totalCount}")

        log.info(f"Merging PR: #{pr['number']}")
        try:
            merge_pr(pr["base_ref"], pr["head_ref"])
        except Exception as e:
            if case_param.get("expect_failed_pr_plan", False):
                pytest.skip(
                    "Skipping downstream tests since `expect_failed_pr_plan` is set to True"
                )
            else:
                raise e

    @timeout_decorator.timeout(600)
    @pytest.mark.dependency()
    def test_create_deploy_stack_codebuild(self, request, case_param, mut_output, pr):
        """Assert create deploy stack codebuild status matches it's expected status"""
        depends(request, [f"{request.cls.__name__}::test_pr_merge"])

        # needed for the wait_for_lambda_invocation() start_time arg within the first test_trigger_sf iteration so
        # the log group filter will have a wide enough time range
        log.info("Setting first target execution start time")
        request.cls.execution_testing_start_time = int(
            datetime.now().timestamp() * 1000
        )

        log.info("Giving build time to start")
        time.sleep(5)

        status = utils.get_build_finished_status(
            mut_output["codebuild_create_deploy_stack_name"],
            filters={"sourceVersion": f'pr/{pr["number"]}'},
        )[0]

        # used for cases where rollback new provider resources executions were not executed beforehand so build is expected to fail
        if case_param.get("expect_failed_create_deploy_stack", False):
            log.info("Assert build failed")
            assert status == "FAILED"

            log.info(
                f'Assert no execution records exists for commit_id: {pr["head_commit_id"]}'
            )
            with aurora_data_api.connect(
                aurora_cluster_arn=mut_output["metadb_arn"],
                secret_arn=mut_output["metadb_secret_manager_ci_arn"],
                database=mut_output["metadb_name"],
                # recommended for DDL statements
                continue_after_timeout=True,
            ) as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        f"""
                        SELECT COUNT(*)
                        FROM executions
                        WHERE commit_id = '{pr["head_commit_id"]}'
                    """
                    )
                    results = cur.fetchone()

            log.debug(f"Results: {results}")
            assert results[0] == 0

            pytest.skip(
                "Skipping downstream tests since `expect_failed_create_deploy_stack` is set to True"
            )
        else:
            log.info("Assert build succeeded")
            assert status == "SUCCEEDED"

            with aurora_data_api.connect(
                aurora_cluster_arn=mut_output["metadb_arn"],
                secret_arn=mut_output["metadb_secret_manager_ci_arn"],
                database=mut_output["metadb_name"],
                # recommended for DDL statements
                continue_after_timeout=True,
            ) as conn:
                with conn.cursor() as cur:

                    cur.execute(
                        f"""
                    SELECT array_agg(execution_id::TEXT)
                    FROM executions
                    WHERE commit_id = '{pr["head_commit_id"]}'
                    """
                    )
                    results = cur.fetchone()

            ids = results[0]

            if ids is None:
                target_execution_ids = []
            else:
                target_execution_ids = [id for id in ids]

            log.debug(f"Commit execution IDs:\n{target_execution_ids}")

            log.info(
                "Assert that all expected execution records are within executions table"
            )
            assert len(case_param["executions"]) == len(target_execution_ids)

    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_trigger_sf(self, request, mut_output):
        """
        Assert that there are no errors within the latest invocation of the trigger Step Function Lambda

        Depends on create deploy stack codebuild status to be successful to ensure that errors produce by
        the Lambda function are not caused by the build
        """
        depends(
            request, [f"{request.cls.__name__}::test_create_deploy_stack_codebuild"]
        )

        if int(request.node.callspec.id) + 1 != len(request.cls.executions):
            # needed for the wait_for_lambda_invocation() start_time arg within the next test_trigger_sf iteration to
            # ensure that the logs are only associated with the current target_execution parameter
            log.info("Setting next target execution start time")
            current_test_param = int(
                re.search(
                    r"(?<=\[).+(?=\])", os.environ.get("PYTEST_CURRENT_TEST")
                ).group(0)
            )
            request.cls.executions[current_test_param + 1]["testing_start_time"] = int(
                datetime.now().timestamp() * 1000
            )
        elif len(request.cls.executions) == 1:
            # needed for the wait_for_lambda_invocation() start_time arg within the test_merge_lock_unlocked test
            # sets the start_time for current execution iteration given there is only one execution
            log.info("Setting target execution start time")
            current_test_param = int(
                re.search(
                    r"(?<=\[).+(?=\])", os.environ.get("PYTEST_CURRENT_TEST")
                ).group(0)
            )
            request.cls.executions[current_test_param]["testing_start_time"] = int(
                datetime.now().timestamp() * 1000
            )

        if getattr(request.cls, "expect_failed_trigger_sf", False):
            utils.wait_for_lambda_invocation(
                mut_output["trigger_sf_function_name"],
                datetime.utcfromtimestamp(
                    request.cls.executions[int(request.node.callspec.id)][
                        "testing_start_time"
                    ]
                    / 1000
                ),
                expected_count=1,
                timeout=60,
            )

            results = utils.get_latest_log_stream_errs(
                mut_output["trigger_sf_log_group_name"],
                start_time=request.cls.testing_start_time,
                end_time=int(datetime.now().timestamp() * 1000),
            )

            assert len(results) > 0

        else:
            results = utils.get_latest_log_stream_errs(
                mut_output["trigger_sf_log_group_name"],
                start_time=request.cls.execution_testing_start_time,
                end_time=int(datetime.now().timestamp() * 1000),
            )

            assert len(results) == 0

    @timeout_decorator.timeout(
        300,
        exception_message="Trigger SF Lambda did not create rollback provider executions",
    )
    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_rollback_providers_executions_exists(
        self, request, mut_output, case_param, pr
    ):
        """Assert that trigger Step Function Lambda created the correct amount of rollback new provider resource executions"""
        depends(
            request,
            [f"{request.cls.__name__}::test_trigger_sf[{request.node.callspec.id}]"],
        )

        if getattr(request.cls, "expect_failed_trigger_sf", False):
            pytest.skip("Previous trigger SF Lambda invocation failed")

        # get count of rollback provider executions expected
        expected_execution_count = len(
            [
                1
                for cfg in case_param["executions"].values()
                if "rollback_providers" in cfg.get("actions", {})
            ]
        )

        if (
            not request.cls.executions[int(request.node.callspec.id)].get(
                "test_rollback_providers_executions_exists", False
            )
            or expected_execution_count == 0
        ):
            return

        target_execution_ids = []
        while len(target_execution_ids) == 0:
            time.sleep(10)
            with aurora_data_api.connect(
                aurora_cluster_arn=mut_output["metadb_arn"],
                secret_arn=mut_output["metadb_secret_manager_ci_arn"],
                database=mut_output["metadb_name"],
                # recommended for DDL statements
                continue_after_timeout=True,
            ) as conn:
                with conn.cursor() as cur:

                    cur.execute(
                        f"""
                    SELECT array_agg(execution_id::TEXT)
                    FROM executions
                    WHERE commit_id = '{pr["head_commit_id"]}'
                    AND is_rollback = true
                    AND cardinality(new_providers) > 0
                    """
                    )
                    results = cur.fetchone()

            ids = results[0]
            if ids is None:
                target_execution_ids = []
            else:
                target_execution_ids = [id for id in ids]

        log.debug(f"Commit execution IDs:\n{target_execution_ids}")

        assert expected_execution_count == len(target_execution_ids)

    @timeout_decorator.timeout(
        300,
        exception_message="Expected atleast one untested execution to have a status of ('running', 'aborted', 'failed')",
    )
    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_target_execution_record_exists(self, request, mut_output, pr, case_param):
        """Queries metadb until the target execution record exists and adds record to request fixture"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_rollback_providers_executions_exists[{request.node.callspec.id}]"
            ],
        )
        tested_executions = [
            e["record"]["execution_id"]
            for e in request.cls.executions
            if e.get("record", False)
        ]
        log.debug(f"Already tested execution IDs:\n{tested_executions}")

        results = None
        while not results:
            time.sleep(10)
            with aurora_data_api.connect(
                aurora_cluster_arn=mut_output["metadb_arn"],
                secret_arn=mut_output["metadb_secret_manager_ci_arn"],
                database=mut_output["metadb_name"],
                # recommended for DDL statements
                continue_after_timeout=True,
            ) as conn:
                with conn.cursor() as cur:

                    cur.execute(
                        f"""
                        SELECT *
                        FROM executions
                        WHERE commit_id = '{pr["head_commit_id"]}'
                        AND "status" IN ('running', 'aborted', 'failed')
                        AND NOT (execution_id = ANY (ARRAY{tested_executions}::TEXT[]))
                        LIMIT 1
                    """
                    )
                    results = cur.fetchone()

        record = {}
        row = [value for value in results]
        for i, description in enumerate(cur.description):
            record[description.name] = row[i]

        log.debug(f"Target Execution Record:\n{pformat(record)}")

        if record["is_rollback"]:
            request.cls.executions[int(request.node.callspec.id)][
                "action"
            ] = case_param["executions"][record["cfg_path"]]["actions"][
                "rollback_providers"
            ]
        else:
            request.cls.executions[int(request.node.callspec.id)]["action"] = (
                case_param["executions"][record["cfg_path"]]
                .get("actions", {})
                .get("deploy", None)
            )

        log.info("Putting record into request execution dict")
        request.cls.executions[int(request.node.callspec.id)]["record"] = record

    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_sf_execution_aborted(self, request, mut_output, case_param):
        """
        Assert that the execution record has an assoicated Step Function execution that is aborted or doesn't exist if
        the upstream execution was rejected before the target Step Function execution was created
        """
        depends(
            request,
            [
                f"{request.cls.__name__}::test_target_execution_record_exists[{request.node.callspec.id}]"
            ],
        )

        record = request.cls.executions[int(request.node.callspec.id)]["record"]

        sf = boto3.client("stepfunctions")

        log.debug(f'Target Execution Status: {["status"]}')
        if record["status"] != "aborted":
            pytest.skip("Execution approval action is not set to `aborted`")

        try:
            execution_arn = [
                execution["executionArn"]
                for execution in sf.list_executions(
                    stateMachineArn=mut_output["state_machine_arn"]
                )["executions"]
                if execution["name"] == record["execution_id"]
            ][0]
        except IndexError:
            log.info(
                "Execution record status was set to aborted before associated Step Function execution was created"
            )
            assert (
                case_param["executions"][record["cfg_path"]]["sf_execution_exists"]
                is False
            )
        else:
            assert (
                sf.describe_execution(executionArn=execution_arn)["status"] == "ABORTED"
            )

    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_sf_execution_exists(self, request, mut_output):
        """Assert execution record has an associated Step Function execution that hasn't been aborted"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_target_execution_record_exists[{request.node.callspec.id}]"
            ],
        )

        sf = boto3.client("stepfunctions")

        record = request.cls.executions[int(request.node.callspec.id)]["record"]

        if record["status"] == "aborted":
            pytest.skip("Execution approval action is set to `aborted`")

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == record["execution_id"]
        ][0]

        assert sf.describe_execution(executionArn=execution_arn)["status"] in [
            "RUNNING",
            "SUCCEEDED",
            "FAILED",
            "TIMED_OUT",
        ]

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_terra_run_plan_codebuild(self, request, mut_output):
        """Assert terra run plan task within Step Function execution succeeded"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_sf_execution_exists[{request.node.callspec.id}]"
            ],
        )

        record = request.cls.executions[int(request.node.callspec.id)]["record"]

        execution_arn = utils.get_execution_arn(
            mut_output["state_machine_arn"], record["execution_id"]
        )
        status_event = utils.get_terra_run_status_event(execution_arn, "Plan")
        log.debug(f"Plan status event:\n{pformat(status_event)}")

        assert status_event["type"] == "TaskSucceeded"

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.mark.dependency()
    @pytest.mark.usefixtures("target_execution")
    def test_approval_request(self, request, mut_output):
        """Assert that there are no errors within the latest invocation of the approval request Lambda function"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_terra_run_plan_codebuild[{request.node.callspec.id}]"
            ],
        )

        record = request.cls.executions[int(request.node.callspec.id)]["record"]

        execution_arn = utils.get_execution_arn(
            mut_output["state_machine_arn"], record["execution_id"]
        )

        sf = boto3.client("stepfunctions")

        submitted = False
        while not submitted:
            time.sleep(10)

            events = sf.get_execution_history(
                executionArn=execution_arn, includeExecutionData=True
            )["events"]

            for event in events:
                if event["type"] == "TaskSubmitted":
                    out = json.loads(event["taskSubmittedEventDetails"]["output"])
                    if "Payload" in out:
                        submitted = True

        log.debug(f"Submitted task output:\n{pformat(out)}")

        log.info("Assert Lambda Function response status code is valid")
        assert out["Payload"]["statusCode"] == 200

    @pytest.mark.dependency()
    @pytest.mark.usefixtures("target_execution")
    def test_approval_response(self, request, mut_output):
        """Assert that the approval response returns a success status code"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_approval_request[{request.node.callspec.id}]"
            ],
        )
        record = request.cls.executions[int(request.node.callspec.id)]["record"]
        sf = boto3.client("stepfunctions")

        log.info("Testing Approval Task")

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == record["execution_id"]
        ][0]
        events = sf.get_execution_history(
            executionArn=execution_arn, includeExecutionData=True
        )["events"]

        for event in events:
            if (
                event["type"] == "TaskScheduled"
                and event["taskScheduledEventDetails"]["resource"]
                == "invoke.waitForTaskToken"
            ):
                payload = json.loads(event["taskScheduledEventDetails"]["parameters"])[
                    "Payload"
                ]
                approval_url = payload["ApprovalAPI"]
                voter = payload["Voters"][0]

        log.debug(f"Approval URL: {approval_url}")
        log.debug(f"Voter: {voter}")

        body = {
            "action": request.cls.executions[int(request.node.callspec.id)]["action"],
            "recipient": voter,
        }

        log.debug(f"Request Body:\n{body}")

        response = requests.post(approval_url, data=body).json()
        log.debug(f"Response:\n{response}")

        assert response["statusCode"] == 200

    @pytest.mark.dependency()
    @pytest.mark.usefixtures("target_execution")
    def test_approval_denied(self, request, mut_output):
        """Assert that the Reject task state is executed and that the Step Function output includes a failed status attribute"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]"
            ],
        )
        record = request.cls.executions[int(request.node.callspec.id)]["record"]
        sf = boto3.client("stepfunctions")

        if request.cls.executions[int(request.node.callspec.id)]["action"] == "approve":
            pytest.skip("Approval action is set to `approve`")

        if record["is_rollback"]:
            request.cls.expect_failed_trigger_sf = True
        else:
            request.cls.executions[int(request.node.callspec.id) + 1][
                "test_rollback_providers_executions_exists"
            ] = True

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == record["execution_id"]
        ][0]
        events = sf.get_execution_history(
            executionArn=execution_arn, includeExecutionData=True
        )["events"]

        for event in events:
            if (
                event["type"] == "PassStateExited"
                and event["stateExitedEventDetails"]["name"] == "Reject"
            ):
                out = json.loads(event["stateExitedEventDetails"]["output"])

        log.debug(f"Rejection State Output:\n{pformat(out)}")
        assert out["status"] == "failed"

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_terra_run_deploy_codebuild(self, request, mut_output):
        """Assert terra run deploy task within Step Function execution succeeded"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]"
            ],
        )
        record = request.cls.executions[int(request.node.callspec.id)]["record"]

        if request.cls.executions[int(request.node.callspec.id)]["action"] == "reject":
            pytest.skip("Approval action is set to `reject`")

        execution_arn = utils.get_execution_arn(
            mut_output["state_machine_arn"], record["execution_id"]
        )
        status_event = utils.get_terra_run_status_event(execution_arn, "Deploy")
        log.debug(f"Deploy status event:\n{pformat(status_event)}")

        assert status_event["type"] == "TaskSucceeded"

    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    # runs cleanup builds only if step function deploy task was executed
    @pytest.mark.usefixtures("destroy_scenario_tf_resources")
    def test_sf_execution_status(self, request, mut_output):
        """Assert Step Function execution succeeded"""
        sf = boto3.client("stepfunctions")

        # ensure that if test_target_execution_record_exists fails/skips and doesn't
        # create the request.executions 'action' key, this test won't raise a key error
        # finding the 'action' key within the second dependency logic below and results in skipping the test entirely
        depends(
            request,
            [
                f"{request.cls.__name__}::test_target_execution_record_exists[{request.node.callspec.id}]"
            ],
        )

        if request.cls.executions[int(request.node.callspec.id)]["action"] == "approve":
            depends(
                request,
                [
                    f"{request.cls.__name__}::test_terra_run_deploy_codebuild[{request.node.callspec.id}]"
                ],
            )
        else:
            depends(
                request,
                [
                    f"{request.cls.__name__}::test_approval_denied[{request.node.callspec.id}]"
                ],
            )
        record = request.cls.executions[int(request.node.callspec.id)]["record"]

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == record["execution_id"]
        ][0]
        response = sf.describe_execution(executionArn=execution_arn)
        assert response["status"] == "SUCCEEDED"

    @pytest.mark.dependency()
    def test_merge_lock_unlocked(self, request, mut_output, case_param):
        """Assert that the merge lock is unlocked after the deploy stack is finished"""
        ssm = boto3.client("ssm")

        # if trigger SF fails, the merge lock will not be unlocked
        if getattr(request.cls, "expect_failed_trigger_sf", False):
            pytest.skip("One of the trigger sf Lambda invocations was expected to fail")

        elif case_param.get("expect_failed_create_deploy_stack", False):
            # merge lock should be unlocked if error is caught within
            # build's update_executions_with_new_deploy_stack()
            log.info("Assert merge lock is unlocked")
            assert (
                ssm.get_parameter(Name=mut_output["merge_lock_ssm_key"])["Parameter"][
                    "Value"
                ]
                == "none"
            )

        else:
            last_execution = request.cls.executions[len(request.cls.executions) - 1]

            log.debug(f"Last execution request dict:\n{pformat(last_execution)}")

            depends(
                request,
                [
                    f"{request.cls.__name__}::test_sf_execution_status[{len(request.cls.executions) - 1}]"
                ],
            )

            utils.wait_for_lambda_invocation(
                mut_output["trigger_sf_function_name"],
                datetime.utcfromtimestamp(last_execution["testing_start_time"] / 1000),
                expected_count=1,
                timeout=60,
            )

            log.info("Assert merge lock is unlocked")
            assert (
                ssm.get_parameter(Name=mut_output["merge_lock_ssm_key"])["Parameter"][
                    "Value"
                ]
                == "none"
            )
