import pytest
import os
import logging
import sys
from unittest.mock import patch
import boto3
import uuid
from functions.approval_request.lambda_function import lambda_handler
from tests.helpers.utils import check_ses_sender_email_auth

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


@pytest.fixture(scope="module")
def testing_template():
    ses = boto3.client("ses")
    name = f"test-approval-request-{uuid.uuid4()}"

    log.info("Creating testing SES template")
    ses.create_template(
        Template={"TemplateName": name, "SubjectPart": "foo", "TextPart": "bar"}
    )

    yield name

    log.info("Deleting testing SES template")
    ses.delete_template(TemplateName=name)


@pytest.mark.parametrize(
    "event,sender,expected_status_code",
    [
        pytest.param(
            {
                "ApprovalAPI": "mock-api",
                "Voters": ["success@simulator.amazonses.com"],
                "Path": "test/foo",
                "AccountName": "mock-account",
                "ExecutionName": "run-123",
                "PullRequestID": "1",
                "LogUrlPrefix": "mock-log-prefix",
                "LogStreamPrefix": "mock-stream-prefix",
                "PlanTaskArn": "mock-arn",
            },
            os.environ["TF_VAR_approval_request_sender_email"],
            200,
            id="successful_request",
        ),
        pytest.param(
            {
                "ApprovalAPI": "mock-api",
                "Voters": ["success@simulator.amazonses.com"],
                "Path": "test/foo",
                "AccountName": "mock-account",
                "ExecutionName": "run-123",
                "PullRequestID": "1",
                "LogUrlPrefix": "mock-log-prefix",
                "LogStreamPrefix": "mock-stream-prefix",
                "PlanTaskArn": "mock-arn",
            },
            "invalid_sender@non-existent-email.com",
            500,
            id="invalid_sender",
        ),
    ],
)
@pytest.mark.usefixtures("mock_conn")
def test_lambda_handler(testing_template, event, sender, expected_status_code):
    with patch.dict(
        os.environ,
        {
            "SES_TEMPLATE": testing_template,
            "SENDER_EMAIL_ADDRESS": sender,
        },
    ):
        log.info("Checking if sender email address is authorized to send emails")
        if (
            os.environ["SENDER_EMAIL_ADDRESS"]
            == os.environ["TF_VAR_approval_request_sender_email"]
        ):
            if not check_ses_sender_email_auth(
                os.environ["SENDER_EMAIL_ADDRESS"], send_verify_email=True
            ):
                pytest.fail(
                    f"{os.environ['SENDER_EMAIL_ADDRESS']} is not verified to send emails via SES"
                )

        log.info("Running Lambda Function")
        response = lambda_handler(event, {})

    log.debug(f"Response:\n{response}")

    assert response["statusCode"] == expected_status_code
