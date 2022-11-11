import logging
import re
from pprint import pformat
import datetime

import pytest
from pytest_dependency import depends
import boto3
import requests

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class SanityChecks:
    def test_pr_plan_pending_statuses(self, pr_plan_pending_statuses):
        expected_status = "pending"
        log.info(f"Assert plan commit statuses were set to {expected_status}")
        for status in pr_plan_pending_statuses:
            assert status.state == expected_status
            response = requests.get(status.target_url)
            response.raise_for_status()

    def test_pr_plan_finished_statuses(self, pr_plan_finished_statuses):
        log.info("Assert plan commit statuses were set to expected status")
        expected_status = "success"
        for status in pr_plan_finished_statuses:
            assert status.state == expected_status
            response = requests.get(status.target_url)
            response.raise_for_status()

    def test_create_deploy_stack_task_status(
        self, request, create_deploy_stack_task_status
    ):
        assert create_deploy_stack_task_status.state == "success"

    @pytest.mark.dependency()
    def test_merge_lock_unlocked(self, request, mut_output):
        """Assert that the merge lock is unlocked after the deploy stack is finished"""
        ssm = boto3.client("ssm")
        last_execution = request.cls.executions[len(request.cls.executions) - 1]

        log.debug(f"Last execution request dict:\n{pformat(last_execution)}")

        depends(
            request,
            [
                f"{request.cls.__name__}::test_sf_execution_status[{len(request.cls.executions) - 1}]"
            ],
        )

        log.info("Assert merge lock is unlocked")
        assert (
            ssm.get_parameter(Name=mut_output["merge_lock_ssm_key"])["Parameter"][
                "Value"
            ]
            == "none"
        )

    @pytest.mark.dependency()
    def test_sf_execution_aborted(self, request, mut_output, record, sf_execution):
        """
        Assert that the execution record has an assoicated Step Function execution that is aborted or doesn't exist if
        the upstream execution was rejected before the target Step Function execution was created
        """

        sf = boto3.client("stepfunctions")

        log.debug(f'Target Execution Status: {record["status"]}')
        if record["status"] != "aborted":
            pytest.skip("Execution approval action is not set to `aborted`")

        # execution may have been aborted before creating SF execution
        if sf_execution:
            assert sf_execution["status"] == "ABORTED"

    @pytest.mark.dependency()
    def test_sf_execution_exists(sf_execution, record):
        """Assert execution record has an associated Step Function execution that hasn't been aborted"""
        if record["status"] == "aborted":
            pytest.skip("Execution approval action is set to `aborted`")

        assert sf_execution
        assert sf_execution["status"] in [
            "RUNNING",
            "SUCCEEDED",
            "FAILED",
            "TIMED_OUT",
        ]

    @pytest.mark.dependency()
    def test_terra_run_plan_status(
        self, request, mut_output, record, target_execution, terra_run_plan_status
    ):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert terra_run_plan_status == "TaskSucceeded"

    @pytest.mark.dependency()
    def test_approval_request(self, approval_request):
        """Assert that there are no errors within the latest invocation of the approval request Lambda function"""

        log.info("Assert approval request succeeded")
        assert approval_request["HttpStatusCode"] == 200

    def test_approval_response(self, ses_approval_response):
        """Assert that the approval response returns a success status code"""

        ses_approval_response.raise_for_status()

    @pytest.mark.dependency()
    def test_terra_run_apply_status(
        self, request, mut_output, record, target_execution, terra_run_apply_status
    ):
        """Assert terra run plan task within Step Function execution succeeded"""
        assert terra_run_apply_status == "TaskSucceeded"

    @pytest.mark.dependency()
    def test_sf_execution_status(self, finished_sf_execution, execution_arn):
        """Assert Step Function execution succeeded"""
        assert finished_sf_execution["status"] == "SUCCEEDED"
