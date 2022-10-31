import logging
import os
import uuid
import json
import time

import boto3
import pytest

from tests.helpers.utils import (
    dummy_tf_output,
    get_commit_status,
    assert_terra_run_status,
    get_terra_run_status_check_name,
)

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))


# need support in order to pass custom endpoint URL for terragrunt command with
# --terragrunt-iam-role flag
# @pytest.mark.skip("Waiting on Terragrunt Issue: #2282")
@pytest.mark.usefixtures("mock_sf_cfg")
@pytest.mark.parametrize(
    "push_changes",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output()
            },
        ),
    ],
    indirect=True,
)
def test_plan_succeeds(mut_output, base_input, push_changes):
    case = "TestPlan"
    state_name = "Plan"

    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(base_input),
    )["executionArn"]

    # Give mock execution time to finish
    time.sleep(5)

    status_check_name = get_terra_run_status_check_name(arn, state_name)

    status = get_commit_status(
        mut_output["repo_full_name"], push_changes["commit_id"], status_check_name
    )

    log.info("Assert that expected commit status state is sent")
    assert status == "success"

    assert_terra_run_status(arn, state_name, "TaskSucceeded")


# need support in order to pass custom endpoint URL for terragrunt command with
# --terragrunt-iam-role flag
# @pytest.mark.skip("Waiting on Terragrunt Issue: #2282")
@pytest.mark.usefixtures("mock_sf_cfg")
@pytest.mark.parametrize(
    "push_changes",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output()
            },
        ),
    ],
    indirect=True,
)
def test_apply_succeeds(mut_output, base_input, push_changes):
    case = "TestApply"
    state_name = "Apply"

    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(base_input),
    )["executionArn"]

    # Give mock execution time to finish
    time.sleep(5)

    status_check_name = get_terra_run_status_check_name(arn, state_name)

    status = get_commit_status(
        mut_output["repo_full_name"], push_changes["commit_id"], status_check_name
    )

    log.info("Assert that expected commit status state is sent")
    assert status == "success"

    assert_terra_run_status(arn, state_name, "TaskSucceeded")


@pytest.mark.usefixtures("truncate_executions")
@pytest.mark.skip("not implemented")
def test_failed_apply_task():
    pass
    # create case where apply_role_arn does not have the proper IAM permissions to run apply
    # and terraform creates the new provider resources but fails to create other downstream resources

    # TODO: assert new provider resources that were written to tf state file were added to metadb record's
    # new_resources column

    # TODO: assert commit status == failure
