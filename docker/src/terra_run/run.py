import os
import logging
import subprocess
import sys
import json
import ast
from typing import List

import aurora_data_api
import github
import boto3

sys.path.append(os.path.dirname(__file__) + "/..")
from common.utils import (
    subprocess_run,
    send_commit_status,
    get_task_log_url,
    get_diff_block,
)

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
stream.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
log.addHandler(stream)
log.setLevel(logging.DEBUG)


def get_new_provider_resources(tg_dir: str, new_providers: List[str]) -> List[str]:
    """
    Parses the directory's Terraform state and returns a list of Terraform
    resource addresses that are from the list of specified provider addresses

    Arguments:
        tg_dir: Terragrunt directory to get new provider resources for
        new_providers: List of Terraform resource addresses (e.g. registry.terraform.io/hashicorp/aws)
    """
    cmd = f'terragrunt state pull --terragrunt-working-dir {tg_dir} --terragrunt-iam-role {os.environ["ROLE_ARN"]}'
    run = subprocess_run(cmd)

    # cases where remote state is empty after deployment
    if not run.stdout:
        return []

    return [
        resource["type"] + "." + resource["name"]
        for resource in json.loads(run.stdout)["resources"]
        if resource["provider"].split('"')[1] in new_providers
    ]


def update_new_resources() -> None:
    """
    Inserts new Terraform provider resources into the associated execution record
    """
    if (
        os.environ.get("NEW_PROVIDERS", None) != "[]"
        and os.environ.get("IS_ROLLBACK", None) == "false"
    ):
        new_providers = ast.literal_eval(os.environ["NEW_PROVIDERS"])
        log.info(f"New Providers:\n{new_providers}")

        resources = get_new_provider_resources(os.environ["CFG_PATH"], new_providers)
        log.info(f"New Provider Resources:\n{resources}")

        if len(resources) > 0:
            rds_data_client = boto3.client(
                "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
            )

            log.info("Adding new provider resources to associated execution record")
            with aurora_data_api.connect(
                aurora_cluster_arn=os.environ["AURORA_CLUSTER_ARN"],
                secret_arn=os.environ["AURORA_SECRET_ARN"],
                database=os.environ["METADB_NAME"],
                rds_data_client=rds_data_client,
            ) as conn:
                with conn.cursor() as cur:
                    resources = ",".join(resources)
                    cur.execute(
                        f"""
                    UPDATE executions
                    SET new_resources = string_to_array('{resources}', ',')
                    WHERE execution_id = '{os.environ["EXECUTION_ID"]}'
                    RETURNING new_resources
                    """
                    )

                    log.debug(cur.fetchone())
        else:
            log.info("New provider resources were not created -- skipping")
    else:
        log.info("New provider resources were not created -- skipping")


def comment_terra_run_plan(plan) -> str:
    """Sends a GitHub PR comment for the run's Terraform plan"""
    plan_block = get_diff_block(plan)
    comment = f"""
## Deployment Infrastructure Changes
### Directory: {os.environ["CFG_PATH"]}
### Execution ID: {os.environ["EXECUTION_ID"]}
<details open>
<summary>Plan</summary>
<br>
{plan_block}
</details>
"""
    pr = (
        github.Github(os.environ["GITHUB_TOKEN"], retry=3)
        .get_repo(os.environ["REPO_FULL_NAME"])
        .get_pull(int(os.environ["PR_ID"]))
    )
    pr.create_issue_comment(comment)

    return comment


def main() -> None:
    """
    Primarily this function prints the results of the Terragrunt command. If the
    command fails, the function sends a commit status labeled under the
    Step Function execution task name if enabled. If the execution is applying
    Terraform resources, the function will update the execution's associated
    metadb record with the new provider resources that were created.
    """

    log.debug(f"Command: {os.environ['TG_COMMAND']}")
    try:
        run = subprocess.run(
            os.environ["TG_COMMAND"].split(" "),
            capture_output=True,
            text=True,
            check=True,
        )
        log.info(run.stdout)
        state = "success"
    except subprocess.CalledProcessError as e:
        log.error(e)
        state = "failure"

    log_url = get_task_log_url()

    try:
        if os.environ["STATE_NAME"] == "Plan":
            sf = boto3.client(
                "stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL")
            )
            # send ECS task log url with task token to allow Request Approval state to use log url
            # within approval email
            if os.environ.get("COMMENT_PLAN"):
                log.info("Commenting Terraform plan results")
                comment_terra_run_plan(run.stdout)
            if state == "success":
                output = json.dumps({"LogsUrl": log_url})
                sf.send_task_success(taskToken=os.environ["TASK_TOKEN"], output=output)
            else:
                sf.send_task_failure(taskToken=os.environ["TASK_TOKEN"])

        elif os.environ["STATE_NAME"] == "Apply":
            update_new_resources()

    except Exception as e:
        log.error(e, exc_info=True)
        state = "failure"

    try:
        send = json.loads(os.environ["COMMIT_STATUS_CONFIG"])[os.environ["STATE_NAME"]]
    except KeyError:
        log.error(
            f"Update SSM parameter for commit status config to include: {os.environ['STATE_NAME']}"
        )

    if send:
        send_commit_status(state, log_url)


if __name__ == "__main__":
    main()
