import logging
import json
import os
import sys

import boto3

sys.path.append(os.path.dirname(__file__))
from utils import (
    aws_encode,
    get_email_approval_sig,
    voter_actions,
    get_logger,
)  # noqa : E402

log = get_logger()
log.setLevel(logging.DEBUG)

ssm = boto3.client("ssm")


def get_ses_urls(msg: dict, secret: str, recipient: str) -> dict:
    """
    Returns mapping of approval actions and their respective URL

    Arguments:
        msg: SNS message
        secret: Secret value used for generating authentification signature
        recipient: Email address that will receive the approval URL
    """
    resource_path = "ses"
    common_params = {
        "ex": msg["ExecutionName"],
        "exArn": msg["ExecutionArn"],
        "sm": msg["StateMachineArn"],
        "recipient": recipient,
        "taskToken": msg["TaskToken"],
    }
    urls = {}

    for action in voter_actions:
        query_params = {
            **common_params,
            **{
                "action": action,
                "X-SES-Signature-256": "sha256="
                + get_email_approval_sig(
                    secret, msg["ExecutionName"], recipient, action
                ),
            },
        }
        urls[action] = (
            msg["ApprovalURL"]
            + resource_path
            + "?"
            + "&".join([f"{k}={aws_encode(v)}" for k, v in query_params.items()])
        )

    return urls


def send_approval(msg: dict, secret: str) -> dict:
    """
    Sends approval request to every voter via AWS SES

    Arguments:
        msg: SNS message
        secret: Secret value used for generating authentification signature
    """
    ses = boto3.client("ses")

    template_data = {
        "path": msg["Path"],
        "logs_url": msg["PlanOutput"]["LogsUrl"],
        "execution_name": msg["ExecutionName"],
        "account_name": msg["AccountName"],
        "pr_id": msg["PullRequestID"],
    }
    log.debug(f"Default Template Data:\n{json.dumps(template_data, indent=4)}")

    destinations = []
    # need to create a separate destination object for each address since the
    # approval URL is specific to the address
    for address in msg["Voters"]:
        urls = get_ses_urls(msg, secret, address)
        destinations.append(
            {
                "Destination": {"ToAddresses": [address]},
                "ReplacementTemplateData": json.dumps(
                    {
                        "approve_url": urls["approve"],
                        "reject_url": urls["reject"],
                    }
                ),
            }
        )
    log.debug(f"Destinations\n {json.dumps(destinations, indent=4)}")

    log.info("Sending bulk email")
    output = ses.send_bulk_templated_email(
        Template=os.environ["SES_TEMPLATE"],
        Source=os.environ["SENDER_EMAIL_ADDRESS"],
        DefaultTemplateData=json.dumps(template_data),
        Destinations=destinations,
    )

    log.debug(f"Response:\n{json.dumps(output, indent=4)}")
    failed_count = 0
    for msg in output["Status"]:
        if msg["Status"] != "Success":
            failed_count += 1
            log.error("Email was not successfully sent")
            log.debug(f"Email Status:\n{msg}")

    res = {"statusCode": 200, "message": "All emails were successfully sent"}
    if failed_count > 0:
        res = {
            "statusCode": 500,
            "message": f'{failed_count}/{len(output["Status"])} emails failed to send',
        }

    log.info(f"Sending response:\n{res}")
    return res


def lambda_handler(event, context):
    """Sends approval request email to email addresses associated with Terragrunt path"""
    log.debug(f"Lambda Event:\n{json.dumps(event, indent=4)}")

    msg = json.loads(event["Records"][0]["Sns"]["Message"])

    # secret used for generating signature query param
    secret = ssm.get_parameter(
        Name=os.environ["EMAIL_APPROVAL_SECRET_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    res = send_approval(msg, secret)

    return res
