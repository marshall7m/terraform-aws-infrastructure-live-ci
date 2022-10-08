import pytest
import logging
import boto3
import uuid
import json
import os
import time
from pprint import pformat

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))


base_input = {
    "plan_command": "terraform plan",
    "apply_command": "terraform apply -auto-approve",
    "apply_role_arn": "apply-role-arn",
    "cfg_path": "foo/bar",
    "execution_id": "run-123",
    "is_rollback": False,
    "new_providers": [],
    "plan_role_arn": "plan-role-arn",
    "commit_id": "commit-123",
    "account_name": "dev",
    "pr_id": 1,
    "voters": ["voter-1"],
}

base_output = {
    "cfg_path": "foo/bar",
    "commit_id": "commit-123",
    "execution_id": "run-123",
    "is_rollback": False,
    "new_providers": [],
    "plan_role_arn": "plan-role-arn",
}


@pytest.mark.parametrize(
    "case,sf_input,expected_status,expected_states,expected_output",
    [
        pytest.param(
            "CompleteSuccess",
            base_input,
            "SUCCEEDED",
            ["Plan", "Request Approval", "Approval Results", "Apply", "Success"],
            {**base_output, **{"status": "succeeded"}},
            id="complete_success",
        ),
        pytest.param(
            "ApprovalRejected",
            base_input,
            "SUCCEEDED",
            ["Plan", "Request Approval", "Approval Results", "Reject"],
            {**base_output, **{"status": "failed"}},
            id="approval_rejected",
        ),
        pytest.param(
            "PlanFails",
            base_input,
            "SUCCEEDED",
            ["Plan", "Reject"],
            {**base_output, **{"status": "failed"}},
            id="plan_fails",
        ),
        pytest.param(
            "RequestApprovalFails",
            base_input,
            "SUCCEEDED",
            ["Plan", "Request Approval", "Reject"],
            {**base_output, **{"status": "failed"}},
            id="request_approval_fails",
        ),
        pytest.param(
            "ApplyFails",
            base_input,
            "SUCCEEDED",
            ["Plan", "Request Approval", "Approval Results", "Apply", "Reject"],
            {**base_output, **{"status": "failed"}},
            id="apply_fails",
        ),
    ],
)
def test_flow(
    mut_output, case, sf_input, expected_status, expected_states, expected_output
):
    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(sf_input),
    )["executionArn"]

    # Give mock execution time to finish
    time.sleep(5)

    events = sf.get_execution_history(executionArn=arn)["events"]
    log.debug(f"Events:\n{pformat(events)}")

    states = []
    for e in events:
        if "stateEnteredEventDetails" in e:
            states.append(e["stateEnteredEventDetails"]["name"])
    assert states == expected_states

    for e in events:
        if "executionSucceededEventDetails" in e:
            output = json.loads(e["executionSucceededEventDetails"]["output"])

    assert output == expected_output

    status = sf.describe_execution(executionArn=arn)["status"]
    assert status == expected_status
