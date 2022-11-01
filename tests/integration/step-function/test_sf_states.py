import logging
import os
import uuid
import json
import time

import boto3
import pytest

from tests.helpers.utils import (
    dummy_tf_output,
    assert_sf_state_type,
)

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))


# need support in order to pass custom endpoint URL for terragrunt command with
# --terragrunt-iam-role flag
@pytest.mark.skip("Waiting on Terragrunt Issue: #2282")
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
    """Ensures ECS task for the Plan State runs successfully"""
    case = "TestPlan"
    state_name = "Plan"

    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(base_input),
    )["executionArn"]

    # Give mock execution time to finish
    time.sleep(5)

    assert_sf_state_type(arn, state_name, "TaskSucceeded")


# need support in order to pass custom endpoint URL for terragrunt command with
# --terragrunt-iam-role flag
@pytest.mark.skip("Waiting on Terragrunt Issue: #2282")
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
    """Ensures ECS task for the Apply State runs successfully"""
    case = "TestApply"
    state_name = "Apply"

    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(base_input),
    )["executionArn"]

    # Give mock execution time to finish
    time.sleep(5)

    assert_sf_state_type(arn, state_name, "TaskSucceeded")
