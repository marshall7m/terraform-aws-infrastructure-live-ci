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
gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)


@pytest.fixture
def push_changes(mut_output, request):
    branch = f"test-{uuid.uuid4()}"
    repo = gh.get_repo(mut_output["repo_full_name"])

    yield {"commit_id": push(repo, branch, request.param), "branch": branch}

    log.debug(f"Deleting branch: {branch}")
    ref = repo.get_git_ref(f"heads/{branch}")
    ref.delete()


@pytest.fixture
def send_commit_status(push_changes, mut_output):
    commit = (
        github.Github(os.environ["GITHUB_TOKEN"], retry=3)
        .get_repo(mut_output["repo_full_name"])
        .get_commit(push_changes["commit_id"])
    )

    log.info("Sending commit status")
    commit.create_status(
        state="pending",
        context=mut_output["create_deploy_stack_status_check_name"],
        target_url="http://localhost:8080",
    )


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
def task_output(mut_output, send_commit_status, push_changes):
    # task env vars independent of if resources are remote or not
    task_env_vars = {
        "SOURCE_CLONE_URL": mut_output["repo_clone_url"],
        "REPO_FULL_NAME": mut_output["repo_full_name"],
        "SOURCE_VERSION": push_changes["branch"],
        "STATUS_CHECK_NAME": mut_output["create_deploy_stack_status_check_name"],
        "BASE_REF": push_changes["branch"],
        "HEAD_REF": "feature-123",
        "PR_ID": "1",
        "COMMIT_ID": push_changes["commit_id"],
        "GITHUB_MERGE_LOCK_SSM_KEY": mut_output["merge_lock_ssm_key"],
        "AURORA_CLUSTER_ARN": mut_output["metadb_arn"],
        "AURORA_SECRET_ARN": mut_output["metadb_secret_manager_ci_arn"],
        "TRIGGER_SF_FUNCTION_NAME": mut_output["trigger_sf_function_name"],
        "METADB_NAME": mut_output["metadb_name"],
        "LOG_URL_PREFIX": mut_output["ecs_log_url_prefix"],
        "LOG_STREAM_PREFIX": mut_output["create_deploy_stack_log_stream_prefix"],
    }

    if os.environ.get("IS_REMOTE"):
        log.info("Running task remotely")
        out = ecs.run_task(
            cluster=mut_output["ecs_cluster_arn"],
            count=1,
            launchType="FARGATE",
            taskDefinition=mut_output["ecs_create_deploy_stack_definition_arn"],
            networkConfiguration=mut_output["ecs_network_config"],
            overrides={
                "containerOverrides": [
                    {
                        "name": mut_output["ecs_create_deploy_stack_container_name"],
                        "environment": [
                            {"name": key, "value": value}
                            for key, value in task_env_vars.items()
                            if key in ["BASE_REF", "HEAD_REF", "COMMIT_ID", "PR_ID"]
                        ],
                    }
                ]
            },
        )

    else:
        log.info("Running task locally")
        # runs task locally via docker compose
        compose_filepath = f"{os.path.dirname(__file__)}/files/docker-compose.create-deploy-stack.local.yml"

        generate_local_task_compose_file(
            mut_output["ecs_create_deploy_stack_definition_arn"], compose_filepath
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
            + mut_output["ecs_create_deploy_stack_role_arn"],
            "AWS_REGION": mut_output["aws_region"],
            "create_stack_GITHUB_TOKEN": os.environ["GITHUB_TOKEN"],
            "create_stack_SCAN_TYPE": "graph",
            "create_stack_COMMIT_STATUS_CONFIG": json.dumps(
                {mut_output["create_deploy_stack_status_check_name"]: True}
            ),
        }

        with open(f"{os.path.dirname(__file__)}/files/.env", "w") as f:
            for key, value in {**task_env_vars, **testing_env_vars}.items():
                f.writelines(f"{key}={value}\n")

        try:
            out = docker.compose.up(build=True, abort_on_container_exit=True)
        except Exception as e:
            docker.compose.down(remove_orphans=True)

            raise e

    return out


@pytest.mark.usefixtures("truncate_executions", "task_output")
@pytest.mark.parametrize(
    "push_changes", [{"foo/a.tf": dummy_tf_output()}], indirect=True
)
def test_successful_execution(reset_moto_server, terra_setup, mut_output, push_changes):
    """
    Test ensures that the proper IAM permissions for the task role are in place and execution runs
    without any failures
    """
    repo = gh.get_repo(mut_output["repo_full_name"])
    status = [
        status
        for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
        if status.context == mut_output["create_deploy_stack_status_check_name"]
    ][0]

    assert status.state == "success"
