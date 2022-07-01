import os
import logging
import subprocess
import sys
import github

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


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

    commit = github.Github(os.environ["GITHUB_TOKEN"], retry=3).get_repo(
        os.environ["REPO_FULL_NAME"]
    ).get_commit(os.environ["COMMIT_ID"])

    log.info("Sending commit status")
    commit.create_status(
        state=state,
        context=os.environ["STATUS_CHECK_NAME"],
        target_url=[
            s.target_url for s in commit.get_statuses() if s.context == os.environ["STATUS_CHECK_NAME"]
        ][0],
    )


if __name__ == "__main__":
    main()
