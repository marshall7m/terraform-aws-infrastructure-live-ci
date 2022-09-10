import os
import pytest
from python_on_whales import DockerClient
import logging
from tests.helpers.utils import dummy_tf_output, push
import boto3
from github.GithubException import UnknownObjectException
import github
import uuid
import requests
import subprocess
import shlex
from tempfile import NamedTemporaryFile
import json

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

ecs = boto3.client("ecs", endpoint_url=os.environ["MOTO_ENDPOINT_URL"])


@pytest.fixture
def push_changes(repo, request):
    branch = f"test-{uuid.uuid4()}"
    
    yield {
        "commit_id": push(repo, branch, request.param),
        "branch": branch
    }

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
def moto_task_resources():
    """
    Creates mock merge lock ssm param and trigger sf lambda function
    """
    function_name = "mock-trigger-sf"
    lb = boto3.client("lambda", endpoint_url=os.environ["MOTO_ENDPOINT_URL"])
    iam = boto3.client("iam", endpoint_url=os.environ["MOTO_ENDPOINT_URL"])

    def _create():
        function_role_arn = iam.create_service_linked_role(AWSServiceName='lambda.amazonaws.com')["Role"]["Arn"]
        function = lb.create_function(
            FunctionName=function_name,
            Runtime='python3.8',
            Role=function_role_arn,
            Handler='lambda_function.lambda_handler',
            Code={
                'ZipFile': "foo",
            }
        )

        task_role_arn = 

        return {
            "merge_lock_ssm_key": "mock-merge-lock-ssm-key",
            "metadb_arn": "mock-metadb-arn",
            "metadb_secret_manager_ci_arn": "mock-metadb-secret-arn",
            "trigger_sf_function_name": function["FunctionName"],
            "metadb_name": "mock_metadb_name",
            "ecs_create_deploy_stack_role_arn": 
        }

    yield _create

    log.debug("Deleting pytest mock resources")
    lb.delete_function(FunctionName=function_name)

@pytest.fixture
def task_output(mut, repo, push_changes, moto_task_resources):

    # task env vars independent of if resources are remote or not
    task_env_vars = {
        "SOURCE_CLONE_URL": repo.clone_url,
        "REPO_FULL_NAME": repo.full_name,
        "SOURCE_VERSION": push_changes["branch"],
        "STATUS_CHECK_NAME": "CreateDeployStack",
        "BASE_REF": push_changes["branch"],
        "HEAD_REF": "feature-123",
        "PR_ID": "1",
        "COMMIT_ID": push_changes["commit_id"],
    }

    if os.environ.get("SYNC_MODULE") or os.environ.get("IS_REMOTE"):
        # gets task resources from running terraform output on testing terraform configuration fixture directory
        output = mut.run("output", get_cache=False)

    else:
        # gets task resources from fixture that creates them within local moto server
        output = moto_task_resources()

    log.debug(output)
    
    task_env_vars = {**{
        "GITHUB_MERGE_LOCK_SSM_KEY": output["merge_lock_ssm_key"],
        "AURORA_CLUSTER_ARN": output["metadb_arn"],
        "AURORA_SECRET_ARN": output["metadb_secret_manager_ci_arn"],
        "TRIGGER_SF_FUNCTION_NAME": output["trigger_sf_function_name"],
        "METADB_NAME": output["metadb_name"],
    }, **task_env_vars}

    if os.environ.get("IS_REMOTE"):
        # runs task remotely
        x = ""
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
        if os.environ.get("SYNC_MODULE"):
            # gets task def ARN from terraform testing module and converts def to docker compose file
            generate_local_task_compose_file(
                output["ecs_create_deploy_stack_definition_arn"],
                compose_filepath
            )

        docker = DockerClient(
            compose_files=[
                compose_filepath,
                f"{os.path.dirname(__file__)}/files/docker-compose.create-deploy-stack.local.override.yml"
            ],
            compose_env_file=f"{os.path.dirname(__file__)}/.env"
        )

        testing_env_vars = {
            "IAM_ENDPOINT": os.environ["MOTO_ENDPOINT_URL"], # local ecs endpoint will retreive creds from local moto server
            "STS_ENDPOINT": os.environ["MOTO_ENDPOINT_URL"],
            "METADB_ENDPOINT_URL": os.environ["METADB_ENDPOINT_URL"],
            "SSM_ENDPOINT_URL": os.environ["MOTO_ENDPOINT_URL"],
            "LAMBDA_ENDPOINT_URL": os.environ["MOTO_ENDPOINT_URL"],
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI": "/role-arn/" + output["ecs_create_deploy_stack_role_arn"],
        }
        
        with open(f"{os.path.dirname(__file__)}/files/.env", "w") as f:
            for key, value in {**task_env_vars, **testing_env_vars}.items():
                f.writelines(f"{key}={value}\n")

        out = docker.compose.run(
            service="create-stack",
            remove=True
        )

    return out


@pytest.mark.usefixtures("truncate_executions", "reset_moto_server")
@pytest.mark.parametrize("push_changes", [{"foo/a.tf": dummy_tf_output()}], indirect=True)
def test_successful_execution(task_output, terra, repo):
    """
    Test ensures that the proper IAM permissions for the task role are in place and execution runs
    without any failures
    """
    log.debug(task_output)