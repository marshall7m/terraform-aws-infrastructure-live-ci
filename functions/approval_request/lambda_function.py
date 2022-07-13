import boto3
import logging
import json
import os
import re
import urllib

ses = boto3.client("ses")
log = logging.getLogger(__name__)


def aws_encode(value):
    """Encodes value into AWS friendly URL component"""
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


def lambda_handler(event, context):
    """Sends approval request email to email addresses asssociated with Terragrunt path"""

    log = logging.getLogger(__name__)
    log.setLevel(logging.DEBUG)

    log.debug(f"Lambda Event: {event}")

    template_data = {
        "full_approval_api": event["ApprovalAPI"],
        "path": event["Path"],
        "logs_url": event["LogUrlPrefix"]
        + aws_encode(event["LogStreamPrefix"] + event["PlanTaskArn"].split("/")[-1]),
        "execution_name": event["ExecutionName"],
        "account_name": event["AccountName"],
        "pr_id": event["PullRequestID"],
    }

    log.debug(f"Default Template Data:\n{template_data}")

    destinations = []

    # need to create a separate destination object for each address since only
    # the target address is interpolated into message template
    for address in event["Voters"]:
        destinations.append(
            {
                "Destination": {"ToAddresses": [address]},
                "ReplacementTemplateData": json.dumps({"email_address": address}),
            }
        )
    log.debug(f"Destinations\n {destinations}")

    log.info("Sending bulk email")
    try:
        response = ses.send_bulk_templated_email(
            Template=os.environ["SES_TEMPLATE"],
            Source=os.environ["SENDER_EMAIL_ADDRESS"],
            DefaultTemplateData=json.dumps(template_data),
            Destinations=destinations,
        )
    except Exception as e:
        log.error(e, exc_info=True)
        return {
            "statusCode": 500,
            "message": "Unable to send emails",
        }

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
