import os
import logging
import uuid
import json
import shutil
from typing import List

import requests
import pytest
import github
import tftest
import python_on_whales
from python_on_whales import docker
from tests.helpers.utils import push

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

FILE_DIR = os.path.dirname(os.path.dirname(__file__))


def pytest_addoption(parser):
    parser.addoption(
        "--skip-moto-reset", action="store_true", help="skips resetting moto server"
    )

    parser.addoption(
        "--setup-reset-moto-server",
        action="store_true",
        help="Resets moto server on session setup",
    )


def pytest_generate_tests(metafunc):
    tf_versions = [pytest.param("latest")]
    if "terraform_version" in metafunc.fixturenames:
        tf_versions = [pytest.param("latest")]
        metafunc.parametrize(
            "terraform_version",
            tf_versions,
            indirect=True,
            scope="session",
            ids=[f"tf_{v.values[0]}" for v in tf_versions],
        )

    if "tf" in metafunc.fixturenames:
        metafunc.parametrize(
            "tf",
            [f"{os.path.dirname(__file__)}/fixtures"],
            indirect=True,
            scope="session",
        )


@pytest.fixture(scope="session")
def reset_moto_server(request):
    if not os.environ.get("IS_REMOTE", False):
        reset = request.config.getoption("setup_reset_moto_server")
        if reset:
            log.info("Resetting moto server on setup")
            requests.post(f"{os.environ['MOTO_ENDPOINT_URL']}/moto-api/reset")

    yield None

    if os.environ.get("IS_REMOTE", False):
        skip = request.config.getoption("skip_moto_reset")
        if skip:
            log.info("Skip resetting moto server")
        else:
            log.info("Resetting moto server")
            requests.post(f"{os.environ['MOTO_ENDPOINT_URL']}/moto-api/reset")


@pytest.fixture(scope="session")
def docker_ecs_task() -> python_on_whales.Image:
    """Builds Docker image for ECS tasks"""
    # use legacy build since gh actions runner doesn't have buildx
    img = docker.image.legacy_build(
        os.path.join(FILE_DIR, "../docker"),
        cache=True,
        tags=["terraform-aws-infrastructure-live-ci/tasks:latest"],
    )

    return img


@pytest.fixture(scope="session")
def docker_lambda_receiver() -> python_on_whales.Image:
    """Builds Docker image for Lambda receiver function"""
    # use legacy build since gh actions runner doesn't have buildx
    img = docker.image.legacy_build(
        os.path.join(FILE_DIR, "../functions/webhook_receiver"),
        cache=True,
        tags=["terraform-aws-infrastructure-live-ci/receiver:latest"],
    )

    return img


@pytest.fixture(scope="session")
def docker_lambda_approval_response() -> python_on_whales.Image:
    """Builds Docker image for Lambda approval response function"""
    # use legacy build since gh actions runner doesn't have buildx
    img = docker.image.legacy_build(
        os.path.join(FILE_DIR, "../functions/approval_response"),
        cache=True,
        tags=["terraform-aws-infrastructure-live-ci/approval-response:latest"],
    )

    return img


@pytest.fixture(scope="session")
def tfvars_files(
    tmp_path_factory,
    docker_ecs_task,
    docker_lambda_receiver,
    docker_lambda_approval_response,
) -> List[str]:
    """Returns list of tfvars json files to be used for Terraform variables"""
    parent = tmp_path_factory.mktemp("tfvars")
    secret_env_vars = {
        "registry_password": os.environ.get("REGISTRY_PASSWORD"),
        "github_token_ssm_value": os.environ.get("GITHUB_TOKEN"),
    }

    secret_filepath = parent / "secret.auto.tfvars.json"

    with secret_filepath.open("w", encoding="utf-8") as f:
        json.dump(secret_env_vars, f, indent=4, sort_keys=True)

    if os.environ.get("IS_REMOTE", False):
        env_vars = {
            "approval_request_sender_email": os.environ[
                "APPROVAL_REQUEST_SENDER_EMAIL"
            ],
        }
    else:
        # maps local endpoint URLs to terraform variables
        env_vars = {
            "local_task_common_env_vars": [
                {"name": "SSM_ENDPOINT_URL", "value": os.environ["MOTO_ENDPOINT_URL"]},
                {
                    "name": "LAMBDA_ENDPOINT_URL",
                    "value": os.environ["MOTO_ENDPOINT_URL"],
                },
                {"name": "SF_ENDPOINT_URL", "value": os.environ["SF_ENDPOINT_URL"]},
                {"name": "AWS_S3_ENDPOINT", "value": os.environ["MOTO_ENDPOINT_URL"]},
                {
                    "name": "AWS_DYNAMODB_ENDPOINT",
                    "value": os.environ["MOTO_ENDPOINT_URL"],
                },
                {"name": "AWS_IAM_ENDPOINT", "value": os.environ["MOTO_ENDPOINT_URL"]},
                {"name": "AWS_STS_ENDPOINT", "value": os.environ["MOTO_ENDPOINT_URL"]},
                {
                    "name": "METADB_ENDPOINT_URL",
                    "value": os.environ["METADB_ENDPOINT_URL"],
                },
                {"name": "S3_BACKEND_FORCE_PATH_STYLE", "value": True},
            ],
            "ecs_image_address": docker_ecs_task.repo_tags[0],
            "webhook_receiver_image_address": docker_lambda_receiver.repo_tags[0],
            "approval_response_image_address": docker_lambda_approval_response.repo_tags[
                0
            ],
            "approval_sender_arn": "arn:aws:ses:us-west-2:123456789012:identity/fakesender@fake.com",
            "approval_request_sender_email": "fakesender@fake.com",
            "create_approval_sender_policy": "false",
            "moto_endpoint_url": os.environ["MOTO_ENDPOINT_URL"],
            "metadb_endpoint_url": os.environ["METADB_ENDPOINT_URL"],
            "sf_endpoint_url": os.environ["SF_ENDPOINT_URL"],
            "ecs_endpoint_url": os.environ["ECS_ENDPOINT_URL"],
            "metadb_cluster_arn": os.environ["AURORA_CLUSTER_ARN"],
            "metadb_secret_arn": os.environ["AURORA_SECRET_ARN"],
            "metadb_username": os.environ["PGUSER"],
            "metadb_name": os.environ["PGDATABASE"],
            "skip_credentials_validation": True,
            "skip_metadata_api_check": True,
            "skip_requesting_account_id": True,
            "s3_use_path_style": True,
        }

    testing_filepath = parent / "testing.auto.tfvars.json"
    with testing_filepath.open("w", encoding="utf-8") as f:
        json.dump(env_vars, f, indent=4, sort_keys=True)
    filepaths = [testing_filepath, secret_filepath]

    yield filepaths

    shutil.rmtree(parent)


@pytest.fixture(scope="session")
def mut_output(request, reset_moto_server, tfvars_files):
    """Returns dictionary of Terraform output command results"""
    cache_dir = str(request.config.cache.makedir("tftest"))
    log.info(f"Caching Tftest results to {cache_dir}")

    tf = tftest.TerragruntTest(
        tfdir=f"{FILE_DIR}/fixtures/terraform/mut/basic",
        enable_cache=True,
        cache_dir=cache_dir,
    )

    tf.setup(cleanup_on_exit=True, extra_files=tfvars_files, use_cache=True)
    tf.apply(auto_approve=True, use_cache=True)

    return tf.output(use_cache=True)


@pytest.fixture
def push_changes(mut_output, request):
    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"], retry=3)
    branch = f"test-{uuid.uuid4()}"
    repo = gh.get_repo(mut_output["repo_full_name"])

    yield {
        "commit_id": push(repo, branch, request.param),
        "branch": branch,
        "changes": request.param,
    }

    log.debug(f"Deleting branch: {branch}")
    ref = repo.get_git_ref(f"heads/{branch}")
    ref.delete()


@pytest.fixture
def mock_sf_cfg(mut_output):
    """
    Overwrites Step Function State Machine placeholder name with name from Terraform module.
    See here for more info on mock config file:
    https://docs.aws.amazon.com/step-functions/latest/dg/sfn-local-mock-cfg-file.html
    """
    log.info(
        "Replacing placholder state machine name with: "
        + mut_output["step_function_name"]
    )
    mock_path = os.path.join(os.path.dirname(__file__), "mock_sf_cfg.json")
    with open(mock_path, "r") as f:
        cfg = json.load(f)

    cfg["StateMachines"][mut_output["step_function_name"]] = cfg["StateMachines"].pop(
        "Placeholder"
    )

    with open(mock_path, "w") as f:
        json.dump(cfg, f)

    yield mock_path

    log.info("Replacing state machine name back with placholder")
    with open(mock_path, "r") as f:
        cfg = json.load(f)

    cfg["StateMachines"]["Placeholder"] = cfg["StateMachines"].pop(
        mut_output["step_function_name"]
    )

    with open(mock_path, "w") as f:
        json.dump(cfg, f, indent=4, sort_keys=True)
