import pytest
import os
from slack.approval_request import ApprovalRequest
from unittest.mock import patch
import logging
from pprint import pformat


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@patch("slack_sdk.web.WebClient.users_info", return_value={
    "user": {
        "profile": {
            "image_24": "http://s3.amazonaws.com/pix.iemoji.com/images/emoji/apple/ios-12/256/smiling-face-with-open-mouth.png",
            "display_name": "happy user"
        }
    }
})
def test_approval_requests(mock_users_info):
    
    approval = ApprovalRequest(
        "#testing",
        "Infra-Bot",
        "run-123",
        "dev/foo"
    )
    response = approval.send_approval().data

    # TODO: create assertions for the approval build block contents
    # assert approved/rejected votes content contains text "0 votes"