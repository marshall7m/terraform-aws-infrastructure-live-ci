import logging
from slack.approval_request import ApprovalRequest
from slack import approval_response
import pytest
from slack_sdk.web import WebClient

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

slack_client = WebClient()

@pytest.mark.usefixtures("slack_app")
class TestApprovalResponse:
    def test_vote_approve(self, approval_request):
        log.info("Sending approval request message")
        approval_request.send_approval()

        log.debug("Casting approval vote")
        
        log.debug("Getting approval message")
        slack_client.conversations_history(
            channel=approval_request.channel,
            inclusive=True,
            oldest=approval_request.timestamp,
            limit=1
        )

        log.debug("Assert approval votes is updated")