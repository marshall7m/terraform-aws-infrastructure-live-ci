import logging
import re
import time
import timeout_decorator

import pytest
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

    def test_sf_execution_aborted(
        self, request, mut_output, record, approved_sf_execution
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

    @pytest.mark.skip("Not supported")
    def test_terra_run_plan_status(self, terra_run_plan_finished_task):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert len(terra_run_plan_finished_task["failures"]) == 0

    def test_terra_run_plan_commit_status(self, terra_run_plan_commit_status):
        assert terra_run_plan_commit_status.state == "success"

    def test_approval_request(self, approval_request):
        """Assert approval request succeeded"""
        assert approval_request["HttpStatusCode"] == 200

    def test_approval_response(self, ses_approval_response):
        """Assert that the approval response returns a success status code"""
        log.debug("Response: \n%s", ses_approval_response.text)
        ses_approval_response.raise_for_status()

    # TODO: add once StartedBy parameter is supported:
    # https://repost.aws/questions/QUFtDBO45hTWq3wxnMbsWWKg/aws-step-function-ecs-started-by-parameter-support
    @pytest.mark.skip("Not supported")
    def test_terra_run_apply_status(self, terra_run_apply_finished_task):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert len(terra_run_apply_finished_task["failures"]) == 0

    def test_terra_run_apply_commit_status(self, terra_run_apply_commit_status):
        assert terra_run_apply_commit_status.state == "success"

    def test_sf_execution_status(self, finished_sf_execution):
        """Assert Step Function execution succeeded"""
        assert finished_sf_execution["status"] == "SUCCEEDED"

    def test_merge_lock_unlocked(self, request, mut_output, target_execution):
        """Assert that the expected merge lock is unlocked depending on if the last Step Execution finished"""
        if target_execution == (len(request.cls.case["executions"]) - 1):
            log.info("Assert merge lock is unlocked")
            ssm = boto3.client("ssm")
            max_attempts = 3
            attempt = 0
            merge_lock = ""
            while merge_lock != "none":
                if attempt == max_attempts:
                    raise TimeoutError(
                        "Max attempt reached -- Merge lock is still locked"
                    )

                merge_lock = ssm.get_parameter(Name=mut_output["merge_lock_ssm_key"])[
                    "Parameter"
                ]["Value"]
                log.debug("Merge lock value: %s", merge_lock)

                time.sleep(10)
                attempt += 1
        else:
            pytest.skip("Finished execution was not the last execution")
