
import logging
import os
from pprint import pformat
from slack_bolt import App
from slack_bolt.adapter.aws_lambda import SlackRequestHandler
from slack_sdk.signature import SignatureVerifier
from slack.approval_request import ApprovalRequest
import json
from werkzeug.wrappers import Request, Response



log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

signature_verifier = SignatureVerifier(signing_secret=os.environ.get("SLACK_SIGNING_SECRET"))

class ClientException(Exception):
    """Wraps around client-related errors"""

    pass


def verify_request(event):
    if not signature_verifier.is_valid(
        body=event.get_data(),
        timestamp=event.headers.get("X-Slack-Request-Timestamp"),
        signature=event.headers.get("X-Slack-Signature")
    ):
        raise ClientException("Unauthorized request")

def validate_interactive_vote_event(payload):
    valid = True
    if payload["type"] != "block_actions":
        return False
    elif payload["actions"][0]["text"]["text"] != "Vote":
        return False
    elif payload["api_app_id"] != os.environ["SLACK_APP_ID"]:
        return False

    return valid


def update_approved(request):
    """Updated execution thread's `Approved` section"""

    payload = request.form.to_dict(flat=False)["payload"]
    if not validate_interactive_vote_event(payload):
        return Response("Interactive event is not a valid vote event")

    log.debug("Updating execution's metadb record votes")
    # TODO: get approver's user_id from approval table
    # use update_vote.sql to update execution record

    record = (["wait"], ["approved"], ["reject"])
    
    approved_ids = record[0]
    rejection_ids = record[1]
    waiting_on_ids = record[2]

    approval = ApprovalRequest(
        os.environ["SLACK_CHANNEL"],
        os.environ["SLACK_BOT_NAME"],
        event.get("execution_id"),
        event.get("cfg_path"),
        waiting_on_ids=waiting_on_ids,
        approved_ids=approved_ids,
        rejection_ids=rejection_ids
    )

    approval.send_approval()

    return Response("Successfully updated approval vote")


def slack_handler(event, context):
    app = App(process_before_response=True)
    SlackRequestHandler.clear_all_log_handlers()
    handler = SlackRequestHandler(app=app)
    return handler.handle(event, context)
