import os
import logging
import subprocess
import sys
import github
import json
from typing import List
import aurora_data_api
import ast
from common.utils import subprocess_run

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


def get_new_provider_resources(tg_dir: str, new_providers: List[str]) -> List[str]:
    """
    Parses the directory's Terraform state and returns a list of Terraform resource addresses that are from the list of specified provider addresses
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
    """Inserts new Terraform provider resources into the associated execution record"""
    if (
        os.environ.get("NEW_PROVIDERS", None) != "[]"
        and os.environ.get("IS_ROLLBACK", None) == "false"
    ):
        new_providers = ast.literal_eval(os.environ["NEW_PROVIDERS"])
        log.info(f"New Providers:\n{new_providers}")

        resources = get_new_provider_resources(os.environ["CFG_PATH"], new_providers)
        log.info(f"New Provider Resources:\n{resources}")

        if len(resources) > 0:
            log.info("Adding new provider resources to associated execution record")
            with aurora_data_api.connect(
                aurora_cluster_arn=os.environ["METADB_CLUSTER_ARN"],
                secret_arn=os.environ["METADB_SECRET_ARN"],
                database=os.environ["METADB_NAME"],
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


def main() -> None:
    """Runs Terragrunt plan command on every Terragrunt directory that has been modified"""

    log.debug(f"Command: {os.environ['TG_COMMAND']}")
    try:
        run = subprocess.run(
            os.environ["TG_COMMAND"].split(" "),
            capture_output=True,
            text=True,
            check=True,
        )
        print(run.stdout)
        state = "success"
    except subprocess.CalledProcessError as e:
        print(e.stderr)
        print(e)
        state = "failure"

    try:
        if os.environ["STATE_NAME"] == "Deploy":
            update_new_resources()
    except Exception as e:
        print(e)
        state = "failure"

    commit = (
        github.Github(os.environ["GITHUB_TOKEN"], retry=3)
        .get_repo(os.environ["REPO_FULL_NAME"])
        .get_commit(os.environ["COMMIT_ID"])
    )

    log.info("Sending commit status")
    commit.create_status(
        state=state,
        context=os.environ["CONTEXT"],
        target_url=[
            s.target_url
            for s in commit.get_statuses()
            if s.context == os.environ["CONTEXT"]
        ][0],
    )


if __name__ == "__main__":
    main()
