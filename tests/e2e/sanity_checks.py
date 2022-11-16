import logging
import re
import time
import timeout_decorator

import pytest
import boto3
import requests

from tests.helpers.utils import get_execution_arn

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
        self,
        mut_output,
        record,
    ):
        """
        Assert that the execution record has an assoicated Step Function execution that is aborted or doesn't exist if
        the upstream execution was rejected before the target Step Function execution was created
        """
        if record["status"] != "aborted":
            pytest.skip("Execution approval action is not set to `aborted`")

        arn = get_execution_arn(mut_output["state_machine_arn"], record["execution_id"])
        # execution may have been aborted before creating SF execution
        if arn:
            execution = sf.describe_execution(executionArn=arn)
            assert execution["status"] == "ABORTED"

    def test_approval_responses(self, ses_approval_responses):
        """Assert that the approval response returns a success status code"""
        fail_test = False
        for address, response in ses_approval_responses.items():
            log.debug("Address: %s", address)
            log.debug("Response: \n%s", response.text)
            try:
                response.raise_for_status()
            # TODO: get exact exception
            except Exception as err:
                fail_test = True
                log.error(err)

        if fail_test:
            pytest.fail(
                "One or more approval responses did not return expected results"
            )

    def test_sf_execution_status(self, finished_sf_execution):
        """Assert Step Function execution succeeded"""
        assert finished_sf_execution["status"] == "SUCCEEDED"

    @pytest.mark.usefixtures("finished_sf_execution")
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
