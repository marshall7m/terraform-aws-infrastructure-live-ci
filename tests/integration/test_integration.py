import pytest
import os
import logging
import sys
import json
import time
from datetime import datetime
import github
import git
import timeout_decorator
import random
import string
from pytest_dependency import depends
import boto3
from pprint import pformat
import requests

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class Integration:
    @pytest.fixture(scope="class", autouse=True)
    def class_start_time(self) -> datetime:
        """Datetime of when the class testing started"""
        time = datetime.today()
        return time

    @pytest.fixture(scope="class")
    def cls_lambda_invocation_count(self, class_start_time):
        """Factory fixture that returns the number of times a Lambda function has runned since the class testing started"""
        invocations = []

        def _get_count(function_name: str, refresh=False) -> int:
            """
            Argruments:
                function_name: Name of the AWS Lambda function
                refresh: Determines if a refreshed invocation count should be returned. If False, returns the locally stored invocation count.
            """
            if refresh:
                log.info("Refreshing the invocation count")
                end_time = datetime.today()
                log.debug(f"Start Time: {class_start_time} -- End Time: {end_time}")

                cw = boto3.client("cloudwatch")

                response = cw.get_metric_statistics(
                    Namespace="AWS/Lambda",
                    MetricName="Invocations",
                    Dimensions=[{"Name": "FunctionName", "Value": function_name}],
                    StartTime=class_start_time,
                    EndTime=end_time,
                    Period=60,
                    Statistics=["SampleCount"],
                    Unit="Count",
                )
                for data in response["Datapoints"]:
                    invocations.append(data["SampleCount"])

            return len(invocations)

        yield _get_count

        invocations = []

    @pytest.fixture(scope="class")
    def case_param(self, request):
        """Class case fixture used to determine the actions within the CI flow and the expected test assertions"""
        return request.cls.case

    @pytest.fixture(scope="class")
    def tested_executions(self):
        """Factory fixture that returns a list of execution IDs that have already been tested. Used to determine what execution ID to test next within downstream fixture."""
        ids = []

        def _add_id(id=None) -> list:
            """
            Arguments:
                id: Execution ID to add the list of already tested executions
            """
            if id is not None:
                ids.append(id)

            return ids

        yield _add_id

        ids = []

    @pytest.fixture(scope="module")
    def tf_destroy_commit_ids(self, mut_output):
        """Creates a list of commit Ids to be used for the source version of the teardown Terragrunt destroy builds"""
        commit_ids = [mut_output["base_branch"]]

        def _add(id=None):
            if id:
                commit_ids.append_id
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

        log.info("Removing PR head ref branch")
        head_ref.delete()

        try:
            log.info("Closing PR")
            pr.edit(state="closed")
        except Exception:
            pass

    def get_execution_task_status(
        self, arn: str, execution_id: str, task_id: str
    ) -> str:
        """
        Gets the task status for a given Step Function execution

        Arguments:
            arn: ARN of the Step Function execution
            execution_id: Name of the Step Function execution
            task_id: Task ID associated with the Step Function
        """
        sf = boto3.client("stepfunctions")
        try:
            execution_arn = [
                execution["executionArn"]
                for execution in sf.list_executions(stateMachineArn=arn)["executions"]
                if execution["name"] == execution_id
            ][0]
        except IndexError as e:
            log.error(f"No Step Function execution exists with name: {execution_id}")
            raise e
        events = sf.get_execution_history(
            executionArn=execution_arn, includeExecutionData=True
        )["events"]

        try:
            task_status_id = [
                event["previousEventId"]
                for event in events
                if event.get("stateExitedEventDetails", {}).get("name", None) == task_id
            ][0]
        except IndexError:
            log.debug("Task status ID could not be found")
            return None

        log.debug(f"Task status ID: {task_status_id}")

        for event in events:
            if event["id"] == task_status_id:
                return event["type"]

    def get_build_finished_status(self, name: str, ids=[], filters={}) -> str:
        """
        Waits for a CodeBuild project build to finish and returns the status

        Arguments:
            name: Name of the CodeBuild project
            ids: Pre-existing CodeBuild project build IDs to get the statuses for
            filters: Attributes builds need to have in order to return their associated statuses.
                All filter attributes need to be matched for the build ID to be chosen. These
                attribute are in regards to the response return by client.batch_get_builds().
        """
        cb = boto3.client("codebuild")
        statuses = ["IN_PROGRESS"]

        if len(ids) == 0:
            ids = cb.list_builds_for_project(projectName=name, sortOrder="DESCENDING")[
                "ids"
            ]

            if len(ids) == 0:
                log.error(f"No builds have runned for project: {name}")
                sys.exit(1)

            log.debug(f"Build Filters:\n{filters}")
            for build in cb.batch_get_builds(ids=ids)["builds"]:
                for key, value in filters.items():
                    if build.get(key, None) != value:
                        ids.remove(build["id"])
                        break
            if len(ids) == 0:
                log.error("No builds have met provided filters")
                sys.exit(1)

        log.debug(f"Getting build statuses for the following IDs:\n{ids}")
        while "IN_PROGRESS" in statuses:
            time.sleep(15)
            statuses = []
            for build in cb.batch_get_builds(ids=ids)["builds"]:
                statuses.append(build["buildStatus"])

        return statuses

    @pytest.fixture(scope="module")
    def destroy_scenario_tf_resources(self, conn, mut_output, tf_destroy_commit_ids):
        yield None

        cb = boto3.client("codebuild")

        log.info("Destroying Terraform provisioned resources from test repository")

        with conn.cursor() as cur:
            cur.execute(
                """
            SELECT account_name, account_path, deploy_role_arn
            FROM account_dim
            """
            )

            accounts = []
            for result in cur.fetchall():
                record = {}
                for i, description in enumerate(cur.description):
                    record[description.name] = result[i]
                accounts.append(record)
        conn.commit()

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
            statuses = Integration().get_build_finished_status(
                mut_output["codebuild_terra_run_name"], ids=ids
            )

            log.info(f"Finished Statuses:\n{statuses}")

    def get_latest_log_stream_errs(
        self, log_group: str, start_time=None, end_time=None
    ) -> list:
        """
        Gets a list of log events that contain the word `ERROR` within the latest stream of the CloudWatch log group

        Arguments:
            log_group: CloudWatch log group name
            start_time:  Start of the time range in milliseconds UTC
            end_time:  End of the time range in milliseconds UTC
        """
        logs = boto3.client("logs")

        stream = logs.describe_log_streams(
            logGroupName=log_group, orderBy="LastEventTime", descending=True, limit=1
        )["logStreams"][0]["logStreamName"]

        log.debug(f"Latest Stream: {stream}")

        log.info("Searching latest log stream for any errors")
        if start_time and end_time:
            log.debug(f"Start Time: {start_time}")
            log.debug(f"End Time: {end_time}")
            return logs.filter_log_events(
                logGroupName=log_group,
                logStreamNames=[stream],
                filterPattern="ERROR",
                startTime=start_time,
                endTime=end_time,
            )["events"]
        else:
            return logs.filter_log_events(
                logGroupName=log_group, logStreamNames=[stream], filterPattern="ERROR"
            )["events"]

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

        status = self.get_build_finished_status(
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

        log.info("Merging PR")
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
    def test_create_deploy_stack_codebuild(
        self, request, conn, case_param, mut_output, pr
    ):
        """Assert create deploy stack codebuild status matches it's expected status"""
        depends(request, [f"{request.cls.__name__}::test_pr_merge"])

        log.info("Giving build time to start")
        time.sleep(5)

        status = self.get_build_finished_status(
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
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT COUNT(*)
                    FROM executions
                    WHERE commit_id = '{pr["head_commit_id"]}'
                """
                )
                results = cur.fetchone()
            conn.commit()
            log.debug(f"Results: {results}")
            assert results[0] == 0

            pytest.skip(
                "Skipping downstream tests since `expect_failed_create_deploy_stack` is set to True"
            )
        else:
            log.info("Assert build succeeded")
            assert status == "SUCCEEDED"

    @pytest.mark.dependency()
    def test_deploy_execution_records_exist(self, request, conn, case_param, pr):
        """
        Assert that all expected execution records are within executions table

        Depends on create deploy stack codebuild status check because if the build fails or is still in progress, the below query
        will return premature or invalid results.
        """
        depends(
            request, [f"{request.cls.__name__}::test_create_deploy_stack_codebuild"]
        )

        with conn.cursor() as cur:
            cur.execute(
                f"""
            SELECT array_agg(execution_id::TEXT)
            FROM executions
            WHERE commit_id = '{pr["head_commit_id"]}'
            """
            )
            ids = cur.fetchone()[0]
        conn.commit()

        if ids is None:
            target_execution_ids = []
        else:
            target_execution_ids = [id for id in ids]

        log.debug(f"Commit execution IDs:\n{target_execution_ids}")

        assert len(case_param["executions"]) == len(target_execution_ids)

    @pytest.mark.dependency()
    def test_trigger_sf(
        self, request, mut_output, class_start_time, wait_for_lambda_invocation
    ):
        """
        Assert that there are no errors within the latest invocation of the trigger Step Function Lambda

        Depends on create deploy stack codebuild status to be successful to ensure that errors produce by
        the Lambda function are not caused by the build
        """
        depends(
            request, [f"{request.cls.__name__}::test_create_deploy_stack_codebuild"]
        )

        log.debug("Waiting on trigger SF Lambda invocation to complete")
        wait_for_lambda_invocation(mut_output["trigger_sf_function_name"])

        log_group = mut_output["trigger_sf_log_group_name"]
        log.debug(f"Log Group: {log_group}")

        start_time = int(class_start_time.timestamp() * 1000)
        end_time = int(class_start_time.timestamp() * 1000)
        log.debug(f"Start Time: {start_time} -- End Time: {end_time}")
        results = self.get_latest_log_stream_errs(
            log_group, start_time=start_time, end_time=end_time
        )

        assert len(results) == 0

    @pytest.fixture(scope="class")
    def wait_for_lambda_invocation(self, cls_lambda_invocation_count):
        """Factory fixture that waits for a Lambda's completed invocation count to be more than the current invocation count stored"""

        def _wait(function_name):
            """
            Arguments:
                function_name: Name of the Lambda function
            """
            current_count = cls_lambda_invocation_count(function_name)
            timeout = time.time() + 60
            refresh_count = current_count
            while current_count == refresh_count:
                if time.time() > timeout:
                    pytest.fail("Trigger SF Lambda Function was not invoked")
                time.sleep(5)
                refresh_count = cls_lambda_invocation_count(function_name, refresh=True)
                log.debug(f"Refresh Count: {refresh_count}")
            return None

        yield _wait

    @pytest.fixture(scope="class")
    def execution_testing_start_time(self):
        """
        Returns the start time for testing the current Step Function execution in UTC milliseconds.
        The start time is used for getting Cloudwatch logs for the trigger Step Function Lambda that runs after the Step Function execution
        to ensure that error logs are only assoicated with the target Step Function execution.
        """
        start_time = []

        def _get_start_time(new=False):
            """
            Arguments:
                new: Determines if a new start time should be created. Used when a new execution is ready to be tested.
            """
            if new:
                start_time.clear()
                start_time.append(int(datetime.now().timestamp() * 1000))
            return start_time[0]

        yield _get_start_time

        start_time.clear()

    @pytest.fixture(scope="class")
    def target_execution(
        self,
        request,
        conn,
        pr,
        mut_output,
        wait_for_lambda_invocation,
        tested_executions,
        case_param,
        execution_testing_start_time,
    ):
        """
        Returns the execution record associated with the Step Function to be tested. Only running or finished executions are selected to be tested
        given that waiting execution records won't have an associated Step Function execution.
        """
        if case_param.get("expect_failed_create_deploy_stack", False):
            pytest.skip(
                "Skipping downstream tests since `expect_failed_create_deploy_stack` is set to True"
            )

        log.debug(f"Already tested execution IDs:\n{tested_executions()}")
        with conn.cursor() as cur:
            cur.execute(
                f"""
                SELECT *
                FROM executions
                WHERE commit_id = '{pr["head_commit_id"]}'
                AND "status" IN ('running', 'aborted', 'failed')
                AND NOT (execution_id = ANY (ARRAY{tested_executions()}::TEXT[]))
                LIMIT 1
            """
            )
            results = cur.fetchone()
        conn.commit()

        record = {}
        if results is not None:
            row = [value for value in results]
            for i, description in enumerate(cur.description):
                record[description.name] = row[i]

            log.debug(f"Target Execution Record:\n{pformat(record)}")

            # needed for filtering out any trigger sf cloudwatch logs from previous executions for test_cw_event_trigger_sf assertions
            log.debug("Pinning target execution testing start time")
            execution_testing_start_time(new=True)

            yield record
        else:
            yield {}

        log.debug("Adding execution ID to tested executions list")
        if record != {}:
            tested_executions(record["execution_id"])

    @pytest.fixture(scope="class")
    def action(self, target_execution, case_param):
        """Returns the approval execution action associated with the target execution record"""
        if target_execution == {}:
            return None
        elif target_execution["is_rollback"]:
            return case_param["executions"][target_execution["cfg_path"]]["actions"][
                "rollback_providers"
            ]
        else:
            return (
                case_param["executions"][target_execution["cfg_path"]]
                .get("actions", {})
                .get("deploy", None)
            )

    @pytest.mark.dependency()
    def test_target_execution_record_exists(self, request, conn, pr, target_execution):
        depends(
            request,
            [
                f"{request.cls.__name__}::test_deploy_execution_records_exist",
                f"{request.cls.__name__}::test_trigger_sf",
            ],
        )

        if target_execution == {}:
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT execution_id
                    FROM executions
                    WHERE commit_id = '{pr["head_commit_id"]}'
                    AND "status" = 'waiting'
                """
                )
                results = cur.fetchall()
            conn.commit()

            log.debug(f"Waiting execution IDs: {results}")
            pytest.fail(
                "Expected atleast one untested execution to have a status of ('running', 'aborted', 'failed')"
            )

    @pytest.mark.dependency()
    def test_sf_execution_aborted(
        self, request, target_execution, mut_output, case_param
    ):
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

        sf = boto3.client("stepfunctions")

        log.debug(f'Target Execution Status: {target_execution["status"]}')
        if target_execution["status"] != "aborted":
            pytest.skip("Execution approval action is not set to `aborted`")

        try:
            execution_arn = [
                execution["executionArn"]
                for execution in sf.list_executions(
                    stateMachineArn=mut_output["state_machine_arn"]
                )["executions"]
                if execution["name"] == target_execution["execution_id"]
            ][0]
        except IndexError:
            log.info(
                "Execution record status was set to aborted before associated Step Function execution was created"
            )
            assert (
                case_param["executions"][target_execution["cfg_path"]][
                    "sf_execution_exists"
                ]
                is False
            )
        else:
            assert (
                sf.describe_execution(executionArn=execution_arn)["status"] == "ABORTED"
            )

    @pytest.mark.dependency()
    def test_sf_execution_exists(self, request, mut_output, target_execution):
        """Assert execution record has an associated Step Function execution that hasn't been aborted"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_target_execution_record_exists[{request.node.callspec.id}]"
            ],
        )

        sf = boto3.client("stepfunctions")

        if target_execution["status"] == "aborted":
            pytest.skip("Execution approval action is set to `aborted`")

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == target_execution["execution_id"]
        ][0]

        assert sf.describe_execution(executionArn=execution_arn)["status"] in [
            "RUNNING",
            "SUCCEEDED",
            "FAILED",
            "TIMED_OUT",
        ]

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.mark.dependency()
    def test_terra_run_plan_codebuild(self, request, mut_output, target_execution):
        """Assert terra run plan task within Step Function execution succeeded"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_sf_execution_exists[{request.node.callspec.id}]"
            ],
        )

        log.info("Testing Plan Task")
        status = None
        while status is None:
            time.sleep(10)
            status = self.get_execution_task_status(
                mut_output["state_machine_arn"],
                target_execution["execution_id"],
                "Plan",
            )

        assert status == "TaskSucceeded"

    @timeout_decorator.timeout(30, exception_message="Task was not submitted")
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

        log_group = mut_output["approval_request_log_group_name"]
        log.debug(f"Log Group: {log_group}")
        results = self.get_latest_log_stream_errs(log_group)

        assert len(results) == 0

    @pytest.mark.dependency()
    def test_approval_response(self, request, action, mut_output, target_execution):
        """Assert that the approval response returns a success status code"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_approval_request[{request.node.callspec.id}]"
            ],
        )
        sf = boto3.client("stepfunctions")

        log.info("Testing Approval Task")

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == target_execution["execution_id"]
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

        body = {"action": action, "recipient": voter}

        log.debug(f"Request Body:\n{body}")

        response = requests.post(approval_url, data=body).json()
        log.debug(f"Response:\n{response}")

        assert response["statusCode"] == 302

    @pytest.mark.dependency()
    def test_approval_denied(self, request, target_execution, mut_output, action):
        """Assert that the Reject task state is executed and that the Step Function output includes a failed status attribute"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]"
            ],
        )
        sf = boto3.client("stepfunctions")

        if action == "approve":
            pytest.skip("Approval action is set to `approve`")

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == target_execution["execution_id"]
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
    @pytest.mark.dependency()
    def test_terra_run_deploy_codebuild(
        self, request, mut_output, target_execution, action
    ):
        """Assert terra run deploy task within Step Function execution succeeded"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]"
            ],
        )

        if action == "reject":
            pytest.skip("Approval action is set to `reject`")

        log.info("Testing Deploy Task")

        status = None
        while status is None:
            time.sleep(10)
            status = self.get_execution_task_status(
                mut_output["state_machine_arn"],
                target_execution["execution_id"],
                "Deploy",
            )

        assert status == "TaskSucceeded"

    @pytest.mark.dependency()
    # runs cleanup builds only if step function deploy task was executed
    @pytest.mark.usefixtures("destroy_scenario_tf_resources")
    def test_sf_execution_status(self, request, mut_output, target_execution, action):
        """Assert Step Function execution succeeded"""
        sf = boto3.client("stepfunctions")

        if action == "approve":
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

        execution_arn = [
            execution["executionArn"]
            for execution in sf.list_executions(
                stateMachineArn=mut_output["state_machine_arn"]
            )["executions"]
            if execution["name"] == target_execution["execution_id"]
        ][0]
        response = sf.describe_execution(executionArn=execution_arn)
        assert response["status"] == "SUCCEEDED"

    @pytest.mark.dependency()
    def test_cw_event_trigger_sf(
        self,
        request,
        mut_output,
        target_execution,
        case_param,
        wait_for_lambda_invocation,
        execution_testing_start_time,
    ):
        """
        Assert trigger Step Function Lambda that runs after the Step Function is finished contains no error logs.
        If `expect_failed_rollback_providers_cw_trigger_sf` is `True` within the target execution's associated case,
        then assert that there are error logs.
        The trigger Step Function Lambda is expected to contain error logs if the execution was a rollback for new provider resources
        and the execution was rejected/failed.
        """
        depends(
            request,
            [
                f"{request.cls.__name__}::test_sf_execution_status[{request.node.callspec.id}]"
            ],
        )

        wait_for_lambda_invocation(mut_output["trigger_sf_function_name"])

        log_group = mut_output["trigger_sf_log_group_name"]
        log.debug(f"Log Group: {log_group}")
        time.sleep(10)
        results = self.get_latest_log_stream_errs(
            log_group,
            start_time=execution_testing_start_time(),
            end_time=int(datetime.now().timestamp() * 1000),
        )
        log.debug(f"Stream Errors:\n{pformat(results)}")
        if target_execution["is_rollback"] and case_param["executions"][
            target_execution["cfg_path"]
        ].get("expect_failed_rollback_providers_cw_trigger_sf", False):
            assert len(results) > 0
        else:
            assert len(results) == 0

    @pytest.mark.dependency()
    def test_rollback_providers_executions_exists(
        self, request, conn, case_param, pr, action, target_execution
    ):
        """Assert that trigger Step Function Lambda created the correct amount of rollback new provider resource executions"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_cw_event_trigger_sf[{request.node.callspec.id}]"
            ],
        )

        if target_execution["is_rollback"] != "true" and action != "reject":
            pytest.skip(
                "Expected approval action is not set to `reject` so rollback provider executions will not be created"
            )
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
            ids = cur.fetchone()[0]
        conn.commit()

        if ids is None:
            target_execution_ids = []
        else:
            target_execution_ids = [id for id in ids]

        log.debug(f"Commit execution IDs:\n{target_execution_ids}")

        expected_execution_count = len(
            [
                1
                for cfg in case_param["executions"].values()
                if "rollback_providers" in cfg.get("actions", {})
            ]
        )

        assert expected_execution_count == len(target_execution_ids)
