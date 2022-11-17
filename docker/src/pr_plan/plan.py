import os
import logging
from pprint import pformat
import subprocess
import sys
import github
import json
from common.utils import get_task_log_url

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
stream.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
log.addHandler(stream)
log.setLevel(logging.DEBUG)


def main() -> None:
    """
    Runs Terragrunt plan command on Terragrunt directory that has been modified
    and send a commit status if enabled.
    """

    cmd = f'terragrunt plan --terragrunt-working-dir {os.environ["CFG_PATH"]} --terragrunt-iam-role {os.environ["ROLE_ARN"]}'
    log.debug(f"Command: {cmd}")
    try:
        run = subprocess.run(cmd.split(" "), capture_output=True, text=True, check=True)
        log.info(run.stdout)
        state = "success"
    except subprocess.CalledProcessError as e:
        log.info(e.stderr)
        log.info(e)
        state = "failure"

    commit_status_config = json.loads(os.environ["COMMIT_STATUS_CONFIG"])
    log.debug(f"Commit status config:\n{pformat(commit_status_config)}")
    if commit_status_config["PrPlan"]:
        commit = (
            github.Github(os.environ["GITHUB_TOKEN"], retry=3)
            .get_repo(os.environ["REPO_FULL_NAME"])
            .get_commit(os.environ["COMMIT_ID"])
        )

        log.info("Sending commit status")
        commit.create_status(
            state=state,
            context=os.environ["STATUS_CHECK_NAME"],
            target_url=get_task_log_url(),
        )


if __name__ == "__main__":
    main()
