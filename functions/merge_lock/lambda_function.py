import boto3
import logging
import json
import os
import requests
import sys
import urllib
import re
from pprint import pformat

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
ssm = boto3.client("ssm")


def aws_encode(value):
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


def lambda_handler(event, context):
    """Creates a PR commit status that shows the current merge lock status"""

    log.debug(f"Event:\n{pformat(event)}")

    payload = json.loads(event["requestPayload"]["body"])

    merge_lock = ssm.get_parameter(Name=os.environ["MERGE_LOCK_SSM_KEY"])["Parameter"][
        "Value"
    ]

    token = ssm.get_parameter(
        Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]
    commit_id = payload["pull_request"]["head"]["sha"]
    repo_full_name = payload["repository"]["full_name"]

    log.info(f"Commit ID: {commit_id}")
    log.info(f"Repo: {repo_full_name}")
    log.info(f"Merge lock value: {merge_lock}")

    approval_url = f"https://{token}:x-oauth-basic@api.github.com/repos/{repo_full_name}/statuses/{commit_id}"  # noqa: E501
    target_url = f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(context.log_group_name)}/log-events/{aws_encode(context.log_stream_name)}'  # noqa: E501

    if merge_lock != "none":
        data = {
            "state": "pending",
            "description": f"Locked -- In Progress PR #{merge_lock}",
            "context": os.environ["STATUS_CHECK_NAME"],
            "target_url": target_url,
        }
    elif merge_lock == "none":
        data = {
            "state": "success",
            "description": "Unlocked",
            "context": os.environ["STATUS_CHECK_NAME"],
            "target_url": target_url,
        }
    else:
        log.error(f"Invalid merge lock value: {merge_lock}")
        sys.exit(1)

    log.debug(f"Response Data:\n{data}")

    log.info("Sending response")
    response = requests.post(approval_url, json=data)
    log.debug(f"Response:\n{response}")
