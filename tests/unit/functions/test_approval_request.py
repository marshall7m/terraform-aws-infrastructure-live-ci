import pytest
import os
import logging
import sys
from unittest.mock import patch
import boto3
import uuid
from functions.approval_request.lambda_function import lambda_handler

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
    "mock_send_bulk_templated_email, expected_status_code",
    [
        pytest.param(
            200,
            id="success",
        ),
    ],
)
@pytest.mark.usefixtures("mock_conn")
@patch("boto3.client")
def test_lambda_handler(
    mock_boto_client, mock_send_bulk_templated_email, expected_status_code
):
    mock_boto_client.return_value = mock_boto_client
    mock_boto_client.send_bulk_templated_email.return_value = (
        mock_send_bulk_templated_email
    )

    log.info("Running Lambda Function")
    response = lambda_handler(event, {})

    log.debug(f"Response:\n{response}")

    assert response["statusCode"] == expected_status_code
