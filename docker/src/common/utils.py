import logging
import subprocess
import github
import os
import requests
from pprint import pformat
import re
import urllib

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TerragruntException(Exception):
    """Wraps around Terragrunt-related errors"""

    pass


class ClientException(Exception):
    """Wraps around client-related errors"""

    pass


def aws_encode(value):
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


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


def send_commit_status(state):
    commit = (
        github.Github(os.environ["GITHUB_TOKEN"], retry=3)
        .get_repo(os.environ["REPO_FULL_NAME"])
        .get_commit(os.environ["COMMIT_ID"])
    )
    log.info("Sending commit status")

    metadata = requests.get(
        os.environ["ECS_CONTAINER_METADATA_URI_V4"] + "/task"
    ).json()
    log.debug(f"Container metadata:\n{pformat(metadata)}")
    task_id = metadata["TaskARN"].split("/")[-1]

    return commit.create_status(
        state=state,
        context=os.environ["CONTEXT"],
        target_url=os.environ["LOG_URL_PREFIX"]
        + aws_encode(os.environ["LOG_STREAM_PREFIX"] + task_id),
    )
