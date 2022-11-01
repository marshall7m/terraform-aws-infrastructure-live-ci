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


@pytest.mark.skip("not implemented")
@pytest.mark.parametrize(
    "case,expected_status,expected_states,expected_output_attr",
    [
        pytest.param(
            "CompleteSuccess",
            "SUCCEEDED",
            ["Plan", "Request Approval", "Approval Results", "Apply", "Success"],
            {"status": "succeeded"},
            id="complete_success",
        ),
        pytest.param(
            "ApprovalRejected",
            "SUCCEEDED",
            ["Plan", "Request Approval", "Approval Results", "Reject"],
            {"status": "failed"},
            id="approval_rejected",
        ),
        pytest.param(
            "PlanFails",
            "SUCCEEDED",
            ["Plan", "Reject"],
            {"status": "failed"},
            id="plan_fails",
        ),
        pytest.param(
            "RequestApprovalFails",
            "SUCCEEDED",
            ["Plan", "Request Approval", "Reject"],
            {"status": "failed"},
            id="request_approval_fails",
        ),
        pytest.param(
            "ApplyFails",
            "SUCCEEDED",
            ["Plan", "Request Approval", "Approval Results", "Apply", "Reject"],
            {"status": "failed"},
            id="apply_fails",
        ),
    ],
)
def test_flow(mut_output, case, expected_status, expected_states, expected_output_attr):
    """
    Test possible scenario at the Step Function execution level. Desires Step Function
    states associated with the parametrized cases are mocked within the mock_sf_cfg fixture.
    """
    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(
            {
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
        ),
    )["executionArn"]

    # Give mock execution time to finish
    time.sleep(5)

    events = sf.get_execution_history(executionArn=arn)["events"]
    log.debug(f"Events:\n{pformat(events)}")

    states = []
    for e in events:
        if "stateEnteredEventDetails" in e:
            states.append(e["stateEnteredEventDetails"]["name"])

        elif "executionSucceededEventDetails" in e:
            output = json.loads(e["executionSucceededEventDetails"]["output"])

    log.info("Assert the expected states are started")
    assert states == expected_states

    log.info("Assert the execution has the expected output attributes")
    assert expected_output_attr.items() <= output.items()

    status = sf.describe_execution(executionArn=arn)["status"]
    log.info("Assert that the execution finished with expected status")
    assert status == expected_status
