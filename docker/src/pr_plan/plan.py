import os
import logging
import subprocess
import sys
from common.utils import send_task_status

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

    send_task_status(state, "Terraform Plan")


if __name__ == "__main__":
    main()
