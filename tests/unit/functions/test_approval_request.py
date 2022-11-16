from urllib.parse import urlparse, parse_qs
import sys
import os
import logging
import json

import pytest
from unittest.mock import patch

from functions.approval_request.lambda_function import send_approval, get_ses_urls
from functions.common_lambda.utils import aws_encode

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


# TODO: use for integration testing when lambda function is invoked
event = {
    "Records": [
        {
            "Sns": {
                "Message": json.dumps(
                    {
                        "ApprovalURL": "https://1234.approval.us-west-2.on.aws",
                        "Voters": ["success@simulator.amazonses.com"],
                        "Path": "test/foo",
                        "AccountName": "mock-account",
                        "ExecutionName": "run-123",
                        "ExecutionArn": "mock-execution-arn",
                        "StateMachineArn": "mock-state-machine-arn",
                        "TaskToken": "mock-token",
                        "PullRequestID": "1",
                        "LogsUrl": "mock-log-url",
                    }
                )
            }
        }
    ]
}

msg = {
    "ApprovalURL": "https://1234.approval.us-west-2.on.aws/",
    "Voters": ["success@simulator.amazonses.com"],
    "Path": "test/foo",
    "AccountName": "mock-account",
    "ExecutionName": "run-123",
    "ExecutionArn": "mock-execution-arn",
    "StateMachineArn": "mock-state-machine-arn",
    "TaskToken": "mock-token",
    "PullRequestID": "1",
    "PlanOuput": {"LogsUrl": "mock-log-url"},
}


def test_get_ses_urls():
    """
    Ensures get_ses_urls() returns the expected URL componentes for each
    approval action
    """
    voter = "voter@company.com"
    response = get_ses_urls(msg, "mock-secret", voter)

    assert sorted(response.keys()) == ["approve", "reject"]

    for action, url in response.items():
        parsed = urlparse(url)

        assert parsed.path == "/ses"

        params = parse_qs(parsed.query, strict_parsing=True)

        assert params["ex"][0] == msg["ExecutionName"]
        assert params["exArn"][0] == msg["ExecutionArn"]
        assert params["sm"][0] == msg["StateMachineArn"]
        assert params["recipient"][0] == aws_encode(voter)
        assert params["taskToken"][0] == msg["TaskToken"]
        assert params["action"][0] == action
        assert params["X-SES-Signature-256"][0].startswith("sha256=")


@pytest.mark.parametrize(
    "mock_statuses,expected_status_code",
    [
        pytest.param(["Success", "Success"], 200, id="send_success"),
        pytest.param(["Success", "Failed"], 500, id="send_failed"),
    ],
)
@patch.dict(os.environ, {"EMAIL_APPROVAL_SECRET_SSM_KEY": "mock-key"})
@patch.dict(
    os.environ,
    {"SES_TEMPLATE": "mock-template", "SENDER_EMAIL_ADDRESS": "user@invalid.com"},
)
@patch("boto3.client")
def test_send_approval_ses_status(mock_client, mock_statuses, expected_status_code):
    """
    Ensures send_approval() returns the expected status code based on the
    status of sending the approval emails
    """
    mock_client.return_value.send_bulk_templated_email.return_value = {
        "Status": [{"Status": status} for status in mock_statuses]
    }

    log.info("Running Lambda Function")
    response = send_approval(msg, "mock-secret")

    log.debug(f"Response:\n{response}")

    assert response["statusCode"] == expected_status_code
