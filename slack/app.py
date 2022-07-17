import logging
from pprint import pformat
import requests
from slack_sdk.web import WebClient
from slack_sdk.signature import SignatureVerifier
from slack.approval_request import ApprovalRequest
from slack_bolt import App

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

app = App()
approvals_sent = {}
signature_verifier = SignatureVerifier(signing_secret=signing_secret)

def verify_request(event):
    if not signature_verifier.is_valid(
        body=request.get_data(),
        timestamp=request.headers.get("X-Slack-Request-Timestamp"),
        signature=request.headers.get("X-Slack-Signature")
    ):
        raise ClientException("Unauthorized request")

def send_approval(channel: str, client: WebClient):
    approval = ApprovalRequest(channel)

    message = approval.get_message_payload()

    response = client.chat_postMessage(**message)


    approval.timestamp = response["ts"]

    if channel not in approvals_sent:
        approvals_sent[channel] = {}
    approvals_sent[channel][execution] = approval



@app.action("approve_button")
def test_update_approved(ack, say):
    ack
def update_approved(event, client):
    """Updated execution thread's `Approved` section"""
    log.debug(f"Event:\n{pformat(event)}")
    channel_id = event.get("channel_id")
    user_id = event.get("user")

    # Get the original approval
    approval = approvals_sent[channel_id][user_id]

    approval.update_approved_avatars("user")

    # Get the new message payload
    message = approval.get_message_payload()

    # Post the updated message in Slack
    updated_message = client.chat_update(**message)

if __name__ == "__main__":
    app.start(3000)