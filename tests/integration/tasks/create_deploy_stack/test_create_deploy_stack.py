import os
import pytest
from python_on_whales import DockerClient
import logging
from tests.helpers.utils import dummy_tf_output, push
import boto3
import github
import uuid
import subprocess
import shlex
from tempfile import NamedTemporaryFile
import json

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

ecs = boto3.client("ecs", endpoint_url=os.environ["MOTO_ENDPOINT_URL"])


@pytest.fixture
def push_changes(mut, request):
    branch = f"test-{uuid.uuid4()}"
    output = {k: v["value"] for k, v in mut.output().items()}
    gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)
    repo = gh.get_repo(output["repo_full_name"])

    yield {"commit_id": push(repo, branch, request.param), "branch": branch}

    log.debug(f"Deleting branch: {branch}")
    ref = repo.get_git_ref(f"heads/{branch}")
    ref.delete()


def generate_local_task_compose_file(task_arn, path, overwrite=True):

    if not overwrite and os.path.exists(path):
        log.debug("Compose file already exists -- skipping overwrite")
        return path
    # use --task-def-remote to retreive definition within command
    # once --endpoint flags is supported properly and the following issue
    # is resolved: https://github.com/aws/amazon-ecs-cli/issues/1151
    task_def = ecs.describe_task_definition(taskDefinition=task_arn)["taskDefinition"]

    with NamedTemporaryFile(delete=False, mode="w+") as tmp:
        json.dump(task_def, tmp)
        tmp.flush()

        cmd = f"ecs-cli local create --force --task-def-file {tmp.name} --output {path}"
        log.debug(f"Running command: {cmd}")
        subprocess.run(shlex.split(cmd), check=True)

    return path


@pytest.fixture
def task_output(mut, push_changes):

    output = {k: v["value"] for k, v in mut.output().items()}

    # task env vars independent of if resources are remote or not
    task_env_vars = {
        "SOURCE_CLONE_URL": output["repo_clone_url"],
        "REPO_FULL_NAME": output["repo_full_name"],
        "SOURCE_VERSION": push_changes["branch"],
        "STATUS_CHECK_NAME": "CreateDeployStack",
        "BASE_REF": push_changes["branch"],
        "HEAD_REF": "feature-123",
        "PR_ID": "1",
        "COMMIT_ID": push_changes["commit_id"],
        "GITHUB_MERGE_LOCK_SSM_KEY": output["merge_lock_ssm_key"],
        "AURORA_CLUSTER_ARN": output["metadb_arn"],
        "AURORA_SECRET_ARN": output["metadb_secret_manager_ci_arn"],
        "TRIGGER_SF_FUNCTION_NAME": output["trigger_sf_function_name"],
        "METADB_NAME": output["metadb_name"],
    }

    if os.environ.get("IS_REMOTE"):
        # runs task remotely
        pass
        # use tf outs to interpolate env vars for docker compose ecs integrations override file
        # still use ecs-cli to convert task to compose
        # out = ecs.run_task(
        #     cluster=os.environ["ECS_CLUSTER_ARN"],
        #     count=1,
        #     launchType="FARGATE",
        #     taskDefinition=output["ecs_create_deploy_stack_definition_arn"],
        #     networkConfiguration=json.loads(os.environ["ECS_NETWORK_CONFIG"]),
        #     overrides={
        #         "containerOverrides": [
        #             {
        #                 "name": output[""],
        #                 "environment": [
        #                     {"name": "BASE_REF", "value": base_ref},
        #                     {"name": "HEAD_REF", "value": head_ref},
        #                     {"name": "PR_ID", "value": str(pr_id)},
        #                     {"name": "COMMIT_ID", "value": head_sha},
        #                 ],
        #             }
        #         ]
        #     },
        # )

    else:
        # runs task locally via docker compose
        compose_filepath = f"{os.path.dirname(__file__)}/files/docker-compose.create-deploy-stack.local.yml"

        generate_local_task_compose_file(
            output["ecs_create_deploy_stack_definition_arn"], compose_filepath
        )

        docker = DockerClient(
            compose_files=[
                compose_filepath,
                f"{os.path.dirname(__file__)}/files/docker-compose.create-deploy-stack.local.override.yml",
                f"{os.path.dirname(__file__)}/files/docker-compose.local-network.yml",
                f"{os.path.dirname(__file__)}/../compose/docker-compose.local-endpoint.yml",
            ],
            compose_env_file=f"{os.path.dirname(__file__)}/files/.env",
        )

        testing_env_vars = {
            "IAM_ENDPOINT": os.environ[
                "MOTO_ENDPOINT_URL"
            ],  # local ecs endpoint will retreive creds from local moto server
            "STS_ENDPOINT": os.environ["MOTO_ENDPOINT_URL"],
            "METADB_ENDPOINT_URL": os.environ["METADB_ENDPOINT_URL"],
            "SSM_ENDPOINT_URL": os.environ["MOTO_ENDPOINT_URL"],
            "LAMBDA_ENDPOINT_URL": os.environ["MOTO_ENDPOINT_URL"],
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "/role-arn/"
            + output["ecs_create_deploy_stack_role_arn"],
            "AWS_REGION": output.get("aws_region", "us-west-2"),
        }

        with open(f"{os.path.dirname(__file__)}/files/.env", "w") as f:
            for key, value in {**task_env_vars, **testing_env_vars}.items():
                f.writelines(f"{key}={value}\n")

        out = docker.compose.up(build=True, abort_on_container_exit=True)

    return out


@pytest.mark.usefixtures("truncate_executions")
@pytest.mark.parametrize(
    "push_changes", [{"foo/a.tf": dummy_tf_output()}], indirect=True
)
def test_successful_execution(task_output):
    """
    Test ensures that the proper IAM permissions for the task role are in place and execution runs
    without any failures
    """
    log.debug(task_output)
