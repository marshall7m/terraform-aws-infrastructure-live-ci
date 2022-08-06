import pytest
from unittest.mock import patch
import logging
import os
from functions.approval_response.lambda_function import (
    app,
    ApprovalHandler,
    ClientException,
)

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

event = {
    "domainName": "url-id.lambda-url.us-west-2.on.aws",
    "queryStringParameters": {"taskToken": "token-123", "ex": "run-123"},
    "body": {
        "X-SES-Signature-256": "foo",
        "action": "approve",
        "recipient": "voter-123",
    },
    "requestContext": {
        "http": {
            "method": "POST",
            "path": "/ses",
        }
    },
}


@pytest.mark.parametrize(
    "event,update_vote_side_effect,authorized_request,expected_status_code",
    [
        pytest.param(event, "success", True, 200, id="success"),
        pytest.param(event, Exception(), True, 500, id="internal_error"),
        pytest.param(
            {
                "requestContext": {
                    "http": {
                        "method": "POST",
                        "path": "/ses",
                    }
                }
            },
            None,
            True,
            400,
            id="invalid_request_fields",
        ),
        pytest.param(event, ClientException(), True, 400, id="client_error"),
        pytest.param(event, None, False, 401, id="invalid_sig"),
    ],
)
@patch.dict(os.environ, {"EMAIL_APPROVAL_SECRET_SSM_KEY": "mock-key"})
@patch("boto3.client")
@patch.object(app, "update_vote")
@patch("hmac.compare_digest")
def test_ses_approve(
    mock_compare_digest,
    mock_update_vote,
    mock_boto_client,
    event,
    update_vote_side_effect,
    authorized_request,
    expected_status_code,
):
    mock_compare_digest.return_value = authorized_request
    mock_update_vote.side_effect = update_vote_side_effect
    mock_boto_client.return_value = mock_boto_client
    mock_boto_client.get_parameter.return_value = {
        "Parameter": {"Value": "mock-secret"}
    }

    handler = ApprovalHandler(app=app)

    response = handler.handle(event, {})
    log.debug(f"Response:\n{response}")

    assert response["statusCode"] == expected_status_code
