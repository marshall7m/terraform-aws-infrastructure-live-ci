import os
import logging
import boto3
import subprocess
import sys
import requests
import urllib
import re
from pprint import pformat

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

    token = ssm.get_parameter(
        Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    headers = {
        "Accept": "application/vnd.github.v3+json",
        "Authorization": f"token {token}",
    }

    statuses = requests.get(os.environ["COMMIT_STATUSES_URL"], headers=headers).json()

    log.debug(f"Commit Statuses:\n{pformat(statuses)}")

    log.info("Sending commit status")
    data = {
        "state": state,
        "description": "Terraform Plan",
        "context": os.environ["CONTEXT"],
        "target_url": [
            s["target_url"] for s in statuses if s["context"] == os.environ["CONTEXT"]
        ][0],
    }
    log.debug(f"Data:\n{pformat(data)}")
    response = requests.post(
        os.environ["COMMIT_URL"],
        headers=headers,
        json=data,
    )
    log.debug(f"Response:\n{response}")


if __name__ == "__main__":
    main()
