import pytest
from pytest_dependency import depends


class SanityChecks:
    def test_create_deploy_stack_task_status(
        self, case_param, create_deploy_stack_task_status
    ):
        if case_param.get("expect_failed_create_deploy_stack", False):
            assert create_deploy_stack_task_status.state == "failure"
        else:
            assert create_deploy_stack_task_status.state == "success"

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

    @pytest.mark.usefixtures("target_execution")
    @pytest.mark.dependency()
    def test_sf_execution_aborted(self, request, mut_output, case_param):
        """
        Assert that the execution record has an assoicated Step Function execution that is aborted or doesn't exist if
        the upstream execution was rejected before the target Step Function execution was created
        """

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

    @pytest.mark.dependency()
    def test_sf_execution_exists(sf_execution, record):
        """Assert execution record has an associated Step Function execution that hasn't been aborted"""
        if record["status"] == "aborted":
            pytest.skip("Execution approval action is set to `aborted`")

        assert sf_execution["status"] in [
            "RUNNING",
            "SUCCEEDED",
            "FAILED",
            "TIMED_OUT",
        ]

    @pytest.mark.dependency()
    def test_terra_run_plan_status(self, request, mut_output, record, target_execution):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert terra_run_plan_status == "TaskSucceeded"

    @pytest.mark.dependency()
    def test_approval_request(self, approval_request_status):
        """Assert that there are no errors within the latest invocation of the approval request Lambda function"""

        log.info("Assert approval request succeeded")
        assert approval_request_status == 200

    def test_approval_response(self, ses_approval_response):
        """Assert that the approval response returns a success status code"""

        ses_approval_response.raise_for_status()

    @pytest.mark.dependency()
    def test_terra_run_plan_status(self, request, mut_output, record, target_execution):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert terra_run_plan_status == "TaskSucceeded"

    @pytest.mark.dependency()
    def test_sf_execution_status(self, finished_sf_execution, execution_arn):
        """Assert Step Function execution succeeded"""
        assert finished_sf_execution["status"] == "SUCCEEDED"
