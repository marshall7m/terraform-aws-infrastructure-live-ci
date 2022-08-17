import boto3
import logging
import json
import os
import sys
from pprint import pformat

sys.path.append(os.path.dirname(__file__) + "/..")
from common_lambda.utils import aws_encode, get_email_approval_sig  # noqa : E402

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


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
    actions = ["approve", "reject"]
    urls = {}

    for action in actions:
        query_params = {
            **common_params,
            **{
                "action": action,
                "X-SES-Signature-256": get_email_approval_sig(
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


def lambda_handler(event, context):
    """Sends approval request email to email addresses asssociated with Terragrunt path"""
    log.debug(f"Lambda Event:\n{pformat(event)}")

    ssm = boto3.client("ssm")
    ses = boto3.client("ses")
    msg = json.loads(event["Records"][0]["Sns"]["Message"])

    template_data = {
        "path": msg["Path"],
        "logs_url": msg["LogsUrl"],
        "execution_name": msg["ExecutionName"],
        "account_name": msg["AccountName"],
        "pr_id": msg["PullRequestID"],
    }

    log.debug(f"Default Template Data:\n{template_data}")

    destinations = []

    # secret used for generating signature query param
    secret = ssm.get_parameter(
        Name=os.environ["EMAIL_APPROVAL_SECRET_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    # need to create a separate destination object for each address since the
    # approval URL is specifc to the address
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
    log.debug(f"Destinations\n {destinations}")

    log.info("Sending bulk email")
    response = ses.send_bulk_templated_email(
        Template=os.environ["SES_TEMPLATE"],
        Source=os.environ["SENDER_EMAIL_ADDRESS"],
        DefaultTemplateData=json.dumps(template_data),
        Destinations=destinations,
    )

    log.debug(f"Response:\n{response}")
    failed_count = 0
    for msg in response["Status"]:
        if msg["Status"] == "Success":
            log.info("Email was succesfully sent")
        else:
            failed_count += 1
            log.error("Email was not successfully sent")
            log.debug(f"Email Status:\n{msg}")

    if failed_count > 0:
        return {
            "statusCode": 500,
            "message": f'{failed_count}/{len(response["Status"])} emails failed to send',
        }

    return {"statusCode": 200, "message": "All emails were successfully sent"}
