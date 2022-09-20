from glob import glob
import os
import subprocess
import logging
import json
from hashlib import sha1
import boto3
import inspect
from tempfile import NamedTemporaryFile
from python_on_whales import DockerClient
from python_on_whales import docker as _docker
from python_on_whales.exceptions import DockerException
import shlex

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

ecs = boto3.client("ecs", endpoint_url=os.environ["MOTO_ENDPOINT_URL"])


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


def run_task(
    task_def_arn,
    task_env_vars: dict,
    local_task_env_vars: dict,
    mut_output: dict,
    compose_files=[],
    compose_dir=None,
):
    """
    Runs ECS task locally or remotely depending IS_REMOTE env var

    Arguments:
        overwrite_task_env_vars: Dictionary of task-specific env vars to overwrite default with
        mut_output: Dictionary of testing Terraform module outputs
        overwrite_compose: Determines if the docker compose file should be created if already exists

    """
    if os.environ.get("IS_REMOTE"):
        log.info("Running task remotely")
        out = ecs.run_task(
            cluster=mut_output["ecs_cluster_arn"],
            count=1,
            launchType="FARGATE",
            taskDefinition=task_def_arn,
            networkConfiguration=mut_output["ecs_network_config"],
            overrides={
                "containerOverrides": [
                    {
                        "name": "TODO",
                        "environment": [
                            {"name": key, "value": value}
                            for key, value in task_env_vars.items()
                        ],
                    }
                ]
            },
        )

    else:
        log.info("Creating ECS local Docker network")
        ecs_network_name = "ecs-local-network"
        try:
            _docker.network.create(
                ecs_network_name,
                attachable=True,
                driver="bridge",
                gateway="169.254.170.1",
                subnet="169.254.170.0/24",
            )
        # TODO: create more granular docker catch
        except DockerException:
            log.info("Network already exists: " + ecs_network_name)

        log.info("Running task locally")
        task_def = ecs.describe_task_definition(taskDefinition=task_def_arn)[
            "taskDefinition"
        ]
        compose_dir_hash = sha1(
            json.dumps(task_def, sort_keys=True, default=str).encode("cp037")
        ).hexdigest()
        if not compose_dir:
            compose_dir = (
                os.path.dirname(inspect.stack()[1].filename) + "/.task-compose"
            )

        compose_dir = os.path.join(compose_dir, compose_dir_hash)
        log.debug("Docker compose directory: " + compose_dir)

        if os.path.exists(compose_dir):
            log.debug("Using cache docker compose directory")
        else:
            log.debug("Creating docker compose directory")
            os.makedirs(compose_dir)
            log.debug("Generating docker compose files")
            generate_local_task_compose_file(
                task_def_arn, os.path.join(compose_dir, "docker-compose.ecs-local.yml")
            )

        compose_files = (
            glob(compose_dir + "/*[!override].yml")
            + glob(compose_dir + "/*override.yml")
            + [os.path.dirname(__file__) + "/docker-compose.local-endpoint.yml"]
            + compose_files
        )

        env_path = os.path.join(compose_dir, ".env")
        docker = DockerClient(
            compose_files=compose_files,
            compose_env_file=env_path,
        )

        # local ecs endpoint will retreive creds from local moto server
        testing_env_vars = {
            "IAM_ENDPOINT": os.environ["MOTO_ENDPOINT_URL"],
            "STS_ENDPOINT": os.environ["MOTO_ENDPOINT_URL"],
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "/role-arn/"
            + mut_output["ecs_plan_role_arn"],
            "AWS_REGION": mut_output["aws_region"],
        }

        with open(env_path, "w") as f:
            for key, value in {
                **task_env_vars,
                **testing_env_vars,
                **local_task_env_vars,
            }.items():
                f.writelines(f"{key}={value}\n")

        try:
            out = docker.compose.up(
                build=True, abort_on_container_exit=True, log_prefix=False
            )
        except Exception as e:
            docker.compose.down(remove_orphans=True)

            raise e

    return out
