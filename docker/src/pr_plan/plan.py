import os
import logging
import boto3
import subprocess
import sys
import requests
import urllib
import re

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

ssm = boto3.client("ssm")


class TerragruntException(Exception):
    """Wraps around Terragrunt-related errors"""

    pass


def aws_encode(value):
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


def main() -> None:
    """Runs Terragrunt plan command on every Terragrunt directory that has been modified"""

    token = ssm.get_parameter(
        Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    commit_url = f"https://{token}:x-oauth-basic@api.github.com/repos/{os.environ['REPO_FULL_NAME']}/statuses/{os.environ['COMMIT_ID']}"  # noqa: E501

    cmd = f'terragrunt plan --terragrunt-working-dir {os.environ["CFG_PATH"]} --terragrunt-iam-role {os.environ["ROLE_ARN"]}'
    log.debug(f"Command: {cmd}")
    try:
        run = subprocess.run(cmd.split(" "), capture_output=True, text=True, check=True)
        print(run.stdout)
        state = "success"
    except subprocess.CalledProcessError as e:
        print(e.stderr)
        print(e)
        state = "failure"

    log.info("Sending commit status")
    response = requests.post(
        commit_url,
        json={
            "state": state,
            "description": "Terraform Plan",
            "context": os.environ["CFG_PATH"],
            "target_url": os.environ["LOG_STREAM_URL"],
        },
    )
    log.debug(f"Response:\n{response}")


if __name__ == "__main__":
    main()
