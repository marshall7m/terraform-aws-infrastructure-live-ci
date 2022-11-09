import pytest
import os
import logging
import json
import time
from datetime import datetime
from functions.common_lambda.utils import get_email_approval_sig, aws_encode
import github
import git
from tests.e2e.conftest import mut_output
import timeout_decorator
import random
import string
import re
from pytest_dependency import depends
import aurora_data_api
import boto3
from pprint import pformat
import requests
from tests.e2e import utils
from tests.helpers.utils import get_sf_approval_state_msg, get_finished_commit_status

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

ecs = boto3.client("ecs")


class E2E:
    executions = []

    @pytest.fixture(scope="class")
    def case_param(self, request):
        """Class case fixture used to determine the actions within the CI flow and the expected test assertions"""
        return request.cls.case

    @pytest.fixture(scope="module")
    def tf_destroy_commit_ids(self, mut_output):
        """Creates a list of commit Ids to be used for the source version of the teardown Terragrunt destroy tasks"""
        commit_ids = [mut_output["base_branch"]]

        def _add(id=None):
            if id:
                commit_ids.append(id)
            return commit_ids

        yield _add

    @timeout_decorator.timeout(30)
    @pytest.fixture(scope="class")
    def merge_lock_pr_status(self, repo, mut_output, pr):
        """Gets merge lock commit status"""

        return get_finished_commit_status(
            mut_output["merge_lock_status_check_name"], repo, pr["head_commit_id"]
        )

    @pytest.fixture(scope="class")
    def case_param_modified_dirs(self, case_param):
        """
        Returns a list of directory paths that contains added or modified files
        from the testing class's case attribute
        """
        return {
            path: cfg
            for path, cfg in case_param["executions"].items()
            if cfg.get("pr_files_content", False)
        }

    @timeout_decorator.timeout(300)
    @pytest.fixture(scope="class")
    def pr_plan_pending_statuses(self, mut_output, pr, repo, case_param_modified_dirs):
        """Assert PR plan tasks initial commit statuses were created"""

        log.info("Waiting for all PR plan commit statuses to be created")
        expected_count = len(case_param_modified_dirs)
        log.debug(f"Expected count: {expected_count}")

        statuses = {}
        wait = 10
        while len(statuses) != expected_count:
            log.debug(f"Waiting {wait} seconds")
            time.sleep(wait)
            statuses = [
                status
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context != mut_output["merge_lock_status_check_name"]
            ]
        return statuses

    def test_pr_plan_pending_statuses(pr_plan_pending_statuses):
        expected_status = "pending"
        log.info(f"Assert plan commit statuses were set to {expected_status}")
        for status in pr_plan_pending_statuses:
            log.debug(f"Context: {status.context}")
            log.debug(f"Logs URL: {status.target_url}")
            assert status.state == expected_status

    @timeout_decorator.timeout(300)
    @pytest.fixture(scope="class")
    def pr_plan_finished_statuses(
        self, pr_plan_pending_statuses, mut_output, pr, repo, case_param_modified_dirs
    ):
        """Assert PR plan tasks commit statuses were updated"""

        log.info("Waiting for all PR plan commit statuses to be updated")
        expected_count = len(case_param_modified_dirs)
        log.debug(f"Expected count: {expected_count}")

        statuses = []
        wait = 15
        while len(statuses) != expected_count:
            log.debug(f"Waiting {wait} seconds")
            time.sleep(wait)
            statuses = [
                status
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context != mut_output["merge_lock_status_check_name"]
                and status.state != "pending"
            ]

            log.debug(f"Finished count: {len(statuses)}")

        return statuses

    def test_pr_plan_finished_statuses(
        self, pr_plan_finished_statuses, case_param_modified_dirs
    ):
        log.info("Assert plan commit statuses were set to expected status")
        for status in pr_plan_finished_statuses:
            expected_status = "success"
            for path, cfg in case_param_modified_dirs.items():
                # checks if the case directory's associated commit status is expected to fail
                if re.match(f"Plan: {re.escape(path)}$", status.context) and cfg.get(
                    "expect_failed_pr_plan", False
                ):
                    expected_status = "failure"
                    break
            log.debug(f"Expected status: {expected_status}")
            log.debug(f"Context: {status.context}")
            log.debug(f"Logs URL: {status.target_url}")
            assert status.state == expected_status

    @timeout_decorator.timeout(30)
    @pytest.fixture(scope="class")
    def merge_pr(self, pr_plan_finished_statuses, mut_output, pr, repo, git_repo):
        """Ensure that the PR merges without error"""

        log.info(f"Merging PR: #{pr['number']}")
        try:
            commit = repo.merge(pr["base_ref"], pr["head_ref"])
        except Exception as e:
            branch = repo.get_branch(branch=mut_output["base_branch"])
            log.debug(
                f"Branch protection enforced for admins: {branch.get_protection().enforce_admins}"
            )
            log.debug(
                f"Status Checks Required: {branch.get_required_status_checks().contexts}"
            )

            merge_lock_status = {
                status.context: status.state
                for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
                if status.context == mut_output["merge_lock_status_check_name"]
            }
            log.debug(f"Merge Lock status: {merge_lock_status}")

            log.error(e, exc_info=True)
            raise e

        yield commit

        log.info(f'Removing PR changes from base branch: {mut_output["base_branch"]}')

        log.debug("Pulling remote changes")
        git_repo.git.reset("--hard")
        git_repo.git.pull()

        log.debug(
            "Removing admin enforcement from branch protection to allow revert pushes to trunk branch"
        )
        branch = repo.get_branch(branch=mut_output["base_branch"])
        branch.remove_admin_enforcement()

        log.debug("Removing required status checks")
        status_checks = branch.get_required_status_checks().contexts
        branch.edit_required_status_checks(contexts=[])
        current_status_checks = status_checks
        while len(current_status_checks) > 0:
            time.sleep(3)
            current_status_checks = branch.get_required_status_checks().contexts

        log.debug("Reverting all changes from testing PRs")
        try:
            log.debug(f"Merge Commit ID: {commit.sha}")

            git_repo.git.revert("-m", "1", "--no-commit", str(commit.sha))
            git_repo.git.commit(
                "-m",
                f"Revert changes from PR: {pr['head_ref']} within fixture teardown",
            )
            git_repo.git.push("origin", "--force")
        except Exception as e:
            raise e
        finally:
            log.debug("Adding admin enforcement back")
            branch.set_admin_enforcement()

            log.debug("Adding required status checks back")
            branch.edit_required_status_checks(contexts=status_checks)

    @timeout_decorator.timeout(600)
    @pytest.mark.dependency()
    def create_deploy_stack_task_status(
        self, request, repo, case_param, mut_output, pr, merge_pr
    ):
        """Assert create deploy stack status matches it's expected status"""

        # needed for the wait_for_lambda_invocation() start_time arg within the first test_trigger_sf iteration so
        # the log group filter will have a wide enough time range
        log.info("Setting first target execution start time")
        request.cls.execution_testing_start_time = int(
            datetime.now().timestamp() * 1000
        )

        return get_finished_commit_status(
            mut_output["create_deploy_stack_status_check_name"],
            repo,
            pr["head_commit_id"],
        )

    def test_create_deploy_stack_task_status(
        self, case_param, create_deploy_stack_task_status
    ):
        if case_param.get("expect_failed_create_deploy_stack", False):
            assert create_deploy_stack_task_status.state == "failure"
        else:
            assert create_deploy_stack_task_status.state == "success"

    def trigger_sf_log_errors(self, create_deploy_stack_task_status, request):
        # gets the current tests parameter value
        test_param = int(
            re.search(r"(?<=\[).+(?=\])", os.environ.get("PYTEST_CURRENT_TEST")).group(
                0
            )
        )
        if int(request.node.callspec.id) + 1 != len(request.cls.executions):
            # needed for the wait_for_lambda_invocation() start_time arg within the next test_trigger_sf iteration to
            # ensure that the logs are only associated with the current target_execution parameter
            test_param = test_param + 1

        request.cls.executions[test_param]["testing_start_time"] = int(
            datetime.now().timestamp() * 1000
        )

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

        return utils.get_latest_log_stream_errs(
            mut_output["trigger_sf_log_group_name"],
            start_time=request.cls.testing_start_time,
            end_time=int(datetime.now().timestamp() * 1000),
        )

    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_trigger_sf(self, case_param, trigger_sf_log_errors):
        """
        Assert that there are no errors within the latest invocation of the trigger Step Function Lambda

        Depends on create deploy stack task status to be successful to ensure that errors produce by
        the Lambda function are not caused by the task
        """
        if case_param.get("expect_failed_trigger_sf", False):
            assert len(trigger_sf_log_errors) > 0
        else:
            assert len(trigger_sf_log_errors) == 0

    @timeout_decorator.timeout(
        300,
        exception_message="Expected atleast one untested execution to have a status of ('running', 'aborted', 'failed')",
    )
    @pytest.mark.usefixtures("target_execution")
    def test_target_execution_record_exists(
        self, request, mut_output, pr, case_param, trigger_sf_log_errors
    ):
        """Queries metadb until the target execution record exists and adds record to request fixture"""
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
                secret_arn=mut_output["metadb_secret_manager_master_arn"],
                database=mut_output["metadb_name"],
            ) as conn:
                with conn.cursor() as cur:

                    cur.execute(
                        f"""
                        SELECT *
                        FROM {mut_output["metadb_schema"]}.executions
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
                .get("apply", None)
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

        log.debug(f'Target Execution Status: {record["status"]}')
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
    def test_terra_run_plan(self, request, mut_output):
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

        utils.assert_terra_run_status(execution_arn, "Plan", "TaskSucceeded")

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.mark.dependency()
    @pytest.mark.usefixtures("target_execution")
    def test_approval_request(self, request, mut_output):
        """Assert that there are no errors within the latest invocation of the approval request Lambda function"""
        depends(
            request,
            [
                f"{request.cls.__name__}::test_terra_run_plan[{request.node.callspec.id}]"
            ],
        )

        record = request.cls.executions[int(request.node.callspec.id)]["record"]

        execution_arn = utils.get_execution_arn(
            mut_output["state_machine_arn"], record["execution_id"]
        )

        sf = boto3.client("stepfunctions")

        status_code = None
        while not status_code:
            time.sleep(10)

            events = sf.get_execution_history(
                executionArn=execution_arn, includeExecutionData=True
            )["events"]

            for event in events:
                if (
                    event.get("taskSubmittedEventDetails", {}).get("resource")
                    == "publish.waitForTaskToken"
                ):
                    out = json.loads(event["taskSubmittedEventDetails"]["output"])
                    status_code = out["SdkHttpMetadata"]["HttpStatusCode"]

        log.info("Assert approval request succeeded")
        assert status_code == 200

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
        msg = get_sf_approval_state_msg(execution_arn)
        approval_url = msg["ApprovalURL"]
        task_token = msg["TaskToken"]
        voter = msg["Voters"][0]

        log.debug(f"Approval URL: {approval_url}")
        log.debug(f"Voter: {voter}")
        headers = {
            "content-type": "application/json",
        }
        query_params = {
            "X-SES-Signature-256": get_email_approval_sig(
                mut_output["email_approval_secret"],
                record["execution_id"],
                voter,
                request.cls.executions[int(request.node.callspec.id)]["action"],
            ),
            "taskToken": task_token,
            "recipient": voter,
            "action": request.cls.executions[int(request.node.callspec.id)]["action"],
            "ex": record["execution_id"],
            "exArn": execution_arn,
        }
        approval_url = (
            approval_url
            + "ses?"
            + "&".join([f"{k}={aws_encode(v)}" for k, v in query_params.items()])
        )

        response = requests.post(approval_url, headers=headers)
        log.debug(f"Response:\n{response.text}")

        response.raise_for_status()

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

        execution_arn = utils.get_execution_arn(
            mut_output["state_machine_arn"], record["execution_id"]
        )

        log.info("Waiting for execution to finish")
        execution_status = None
        while execution_status not in ["SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"]:
            time.sleep(5)
            response = sf.describe_execution(executionArn=execution_arn)
            execution_status = response["status"]
            log.debug(f"Execution status: {execution_status}")

        out = json.loads(response["output"])
        log.debug(f"Execution output: {pformat(out)}")

        log.info(
            "Assert that the Reject task passed a failed status within execution output"
        )
        assert out["status"] == "failed"

    @timeout_decorator.timeout(300, exception_message="Task was not submitted")
    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_terra_run_deploy(self, request, mut_output):
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

        utils.assert_terra_run_status(execution_arn, "Apply", "TaskSucceeded")

    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    # runs cleanup tasks only if step function deploy task was executed
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
                    f"{request.cls.__name__}::test_terra_run_deploy[{request.node.callspec.id}]"
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
            # task's update_executions_with_new_deploy_stack()
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
