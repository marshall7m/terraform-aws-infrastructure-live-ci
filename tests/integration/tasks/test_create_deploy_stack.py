import os
import pytest
from python_on_whales import DockerClient
import logging
from tests.helpers.utils import dummy_tf_output, push
from container_transform.converter import Converter
import boto3

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


ecs = boto3.client("ecs", endpoint_url=os.environ["TF_VAR_moto_endpoint_url"])
"""
- create repository remotely
- clone repository
- create case changes
- push changes
- pass github attr to task env vars
- setup metadb records if needed
- convert ecs task def to docker compose file
- pass docker to compose executor
- assert expected values are present

tests:
- successful
    - assert expected records
    - assert trigger sf was called
- failed
    - assert rollback records
LOCAL_ECS_IMAGE_ADDRESS
"""

def pytest_generate_tests(metafunc):
    if "terra" in metafunc.fixturenames:
        metafunc.parametrize("terra", [
            pytest.param(
                {
                    "binary": "terragrunt",
                    "skip_teardown": True,
                    "env": {
                        "IS_REMOTE": "False",
                        "TF_VAR_ecs_image_address": os.environ["LOCAL_ECS_IMAGE_ADDRESS"],
                        "TF_VAR_approval_sender_arn": "arn:aws:ses:us-west-2:123456789012:identity/fakesender@fake.com",
                        "TF_VAR_approval_request_sender_email": "fakesender@fake.com",
                        "TF_VAR_create_approval_sender_policy": "false"
                    },
                    "tfdir": f"{os.path.dirname(os.path.realpath(__file__))}/../../fixtures/terraform/mut/basic"
                }
            )
        ], indirect=True, scope="module"
    )

@pytest.fixture
def mut(terra):
    terra.setup(cleanup_on_exit=False)
    terra.run("apply", get_cache=True, extra_args={"auto_approve": True})
    return terra

@pytest.mark.usefixtures("truncate_executions")
@pytest.mark.parametrize("changes", [{"foo/a.tf": dummy_tf_output()}])
def test_stack(mut, tmp_path, changes):

    output = mut.run("output", get_cache=True)
    log.debug(output)
    # push(repo, BASE_REF, changes)

    task_def = ecs.describe_task_definition(
        taskDefinition=output["ecs_create_deploy_stack_definition_arn"]
    )["taskDefinition"]

    log.debug(task_def)

    task_def_filepath = tmp_path / "task_def.json"
    task_def_filepath.write_text(task_def)

    conv = Converter(
        filename=task_def_filepath, input_type="ecs", output_type="compose"
    )

    compose = conv.convert()
    log.debug(compose)
    compose_filepath = tmp_path / "docker-compose.yml"
    compose_filepath.write_text(compose)

    docker = DockerClient(compose_files=[compose_filepath])

    # out = docker.compose.execute(
    #     "create-deploy-stack",
    #     envs={
    #         "SOURCE_CLONE_URL": repo.clone_url,
    #         "REPO_FULL_NAME": repo.full_name,
    #         "GITHUB_MERGE_LOCK_SSM_KEY": merge_lock,
    #         "SOURCE_VERSION": BASE_REF,
    #         "STATUS_CHECK_NAME": "CreateDeployStack",
    #         "TRIGGER_SF_FUNCTION_NAME": trigger_sf,
    #         "METADB_NAME": os.environ["METADB_NAME"],
    #         "AURORA_CLUSTER_ARN": os.environ["AURORA_CLUSTER_ARN"],
    #         "AURORA_SECRET_ARN": os.environ["AURORA_SECRET_ARN"],
    #         "BASE_REF": BASE_REF,
    #         "HEAD_REF": "feature-123",
    #         "PR_ID": "1",
    #         "COMMIT_ID": repo.get_branch(BASE_REF).commit.sha,
    #     },
    # )

    log.debug(out)
