import logging
import re
from pprint import pformat
import timeout_decorator

import pytest
from pytest_dependency import depends
import boto3
import requests

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

sf = boto3.client("stepfunctions")
ssm = boto3.client("ssm")


class SanityChecks:
    def test_pr_plan_pending_statuses(self, pr_plan_pending_statuses):
        expected_status = "pending"
        log.info(f"Assert plan commit statuses were set to {expected_status}")
        for status in pr_plan_pending_statuses:
            assert status.state == expected_status
            response = requests.get(status.target_url)
            response.raise_for_status()

    @timeout_decorator.timeout(300)
    def test_pr_plan_finished_statuses(self, pr_plan_finished_statuses):
        log.info("Assert plan commit statuses were set to expected status")
        expected_status = "success"
        for status in pr_plan_finished_statuses:
            assert status.state == expected_status
            response = requests.get(status.target_url)
            response.raise_for_status()

    def test_create_deploy_stack_task_status(self, create_deploy_stack_task_status):
        assert create_deploy_stack_task_status.state == "success"

    @pytest.mark.dependency()
    def test_sf_execution_aborted(
        self, request, mut_output, record, finished_sf_execution
    ):
        """
        Assert that the execution record has an assoicated Step Function execution that is aborted or doesn't exist if
        the upstream execution was rejected before the target Step Function execution was created
        """
        log.debug(f'Target Execution Status: {record["status"]}')
        if record["status"] != "aborted":
            pytest.skip("Execution approval action is not set to `aborted`")

        # execution may have been aborted before creating SF execution
        if finished_sf_execution:
            assert finished_sf_execution["status"] == "ABORTED"

    @pytest.mark.dependency()
    def test_sf_execution_exists(self, execution_arn, record):
        """Assert execution record has an associated Step Function execution that hasn't been aborted"""
        if record["status"] == "aborted":
            pytest.skip("Execution approval action is set to `aborted`")

        status = sf.describe_execution(executionArn=execution_arn)["status"]

        assert status in [
            "RUNNING",
            "SUCCEEDED",
            "FAILED",
            "TIMED_OUT",
        ]

    @pytest.mark.dependency()
    @pytest.mark.skip("Not supported")
    def test_terra_run_plan_status(self, terra_run_plan_finished_task):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert len(terra_run_plan_finished_task["failures"]) == 0

    def test_terra_run_plan_commit_status(self, terra_run_plan_commit_status):
        assert terra_run_plan_commit_status.state == "success"

    @pytest.mark.dependency()
    def test_approval_request(self, approval_request):
        """Assert that there are no errors within the latest invocation of the approval request Lambda function"""

        log.info("Assert approval request succeeded")
        assert approval_request["HttpStatusCode"] == 200

    def test_approval_response(self, ses_approval_response):
        """Assert that the approval response returns a success status code"""
        ses_approval_response.raise_for_status()

    @pytest.mark.dependency()
    # TODO: add once StartedBy parameter is supported:
    # https://repost.aws/questions/QUFtDBO45hTWq3wxnMbsWWKg/aws-step-function-ecs-started-by-parameter-support
    @pytest.mark.skip("Not supported")
    def test_terra_run_apply_status(
        self,
        request,
        mut_output,
        record,
        target_execution,
        terra_run_apply_finished_task,
    ):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert len(terra_run_apply_finished_task["failures"]) == 0

    def test_terra_run_apply_commit_status(self, terra_run_apply_commit_status):
        assert terra_run_apply_commit_status.state == "success"

    @pytest.mark.dependency()
    def test_sf_execution_status(self, finished_sf_execution):
        """Assert Step Function execution succeeded"""
        assert finished_sf_execution["status"] == "SUCCEEDED"

    @pytest.mark.dependency()
    def test_merge_lock_unlocked(self, request, mut_output, target_execution):
        """Assert that the expected merge lock is unlocked depending on if the last Step Execution finished"""
        ssm = boto3.client("ssm")
        merge_lock = ssm.get_parameter(Name=mut_output["merge_lock_ssm_key"])[
            "Parameter"
        ]["Value"]

        if target_execution == (len(request.cls.case["executions"]) - 1):
            log.info("Assert merge lock is unlocked")
            assert merge_lock == "none"
        else:
            pytest.skip("Finished execution was not the last execution")
