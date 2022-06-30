import boto3
import os
import requests
from pprint import pformat
import logging
import subprocess

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TerragruntException(Exception):
    """Wraps around Terragrunt-related errors"""

    pass


class ClientException(Exception):
    """Wraps around client-related errors"""

    pass


def subprocess_run(cmd: str, check=True):
    """subprocess.run() wrapper that logs the stdout and raises a subprocess.CalledProcessError exception and logs the stderr if the command fails
    Arguments:
        cmd: Command to run
    """
    log.debug(f"Command: {cmd}")
    try:
        run = subprocess.run(
            cmd.split(" "), capture_output=True, text=True, check=check
        )
        log.debug(f"Stdout:\n{run.stdout}")
        return run
    except subprocess.CalledProcessError as e:
        log.error(e.stderr)
        raise e


def send_task_status(state, description):
    ssm = boto3.client("ssm")

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
        "description": description,
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
