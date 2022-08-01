import pytest
import os
import logging
import sys
from unittest.mock import patch
from functions.approval_request.lambda_function import lambda_handler  # noqa E401

# noqa E401
log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


event = {
    "ApprovalURL": "mock-url",
    "Voters": ["success@simulator.amazonses.com"],
    "Path": "test/foo",
    "AccountName": "mock-account",
    "ExecutionName": "run-123",
    "PullRequestID": "1",
    "LogUrlPrefix": "mock-log-prefix",
    "LogStreamPrefix": "mock-stream-prefix",
    "PlanTaskArn": "mock-arn",
}


@patch.dict(os.environ, {"EMAIL_APPROVAL_SECRET_SSM_KEY": "mock-key"})
@pytest.mark.parametrize(
    "mock_statuses, expected_status_code",
    [
        pytest.param(
            [
                "Success",
            ],
            200,
            id="success",
        ),
        pytest.param(
            ["Success", "Failed"],
            500,
            id="one_failed",
        ),
    ],
)
@pytest.mark.usefixtures("mock_conn")
@patch.dict(
    os.environ,
    {"SES_TEMPLATE": "mock-template", "SENDER_EMAIL_ADDRESS": "user@invalid.com"},
)
@patch("functions.approval_request.lambda_function.ses")
@patch("boto3.client")
def test_lambda_handler(mock_ssm, mock_ses, mock_statuses, expected_status_code):
    send_return_value = {"Status": [{"Status": status} for status in mock_statuses]}
    mock_ses.send_bulk_templated_email.return_value = send_return_value

    mock_ssm.return_value = mock_ssm
    mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "foo"}}

    log.info("Running Lambda Function")
    response = lambda_handler(event, {})

    log.debug(f"Response:\n{response}")

    assert response["statusCode"] == expected_status_code
