import datetime
import json
import logging
import os
import re
import shutil
import time
import uuid
from typing import List

import aurora_data_api
import github
import pytest
from tftest import TerraformTestError
import python_on_whales
import requests
import tftest
import timeout_decorator
from python_on_whales import docker

from tests.helpers.utils import push, rds_data_client

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)
FILE_DIR = os.path.dirname(__file__)


def pytest_addoption(parser):
    parser.addoption(
        "--until-aws-exp",
        action="store",
        default=os.environ.get("UNTIL_AWS_EXP", False),
        help="The least amount of time until the AWS session token expires in minutes (e.g. 10m) or hours (e.g. 2h)",
    )

    parser.addoption(
        "--skip-moto-reset", action="store_true", help="skips resetting moto server"
    )

    parser.addoption(
        "--setup-reset-moto-server",
        action="store_true",
        help="Resets moto server on session setup",
    )


@pytest.fixture(scope="session", autouse=True)
def aws_session_expiration_check(request):
    """
    Setup fixture that ensures that the AWS session credentials are atleast valid for a defined amount of time so
    that they do not expire during tests
    """
    until_exp = request.config.getoption("until_aws_exp")
    if until_exp:
        log.info(
            "Checking if time until AWS session token expiration meets requirement"
        )
        log.debug(f"Input: {until_exp}")
        if os.environ.get("AWS_SESSION_EXPIRATION", False):
            log.debug(f'AWS_SESSION_EXPIRATION: {os.environ["AWS_SESSION_EXPIRATION"]}')
            exp = datetime.datetime.strptime(
                os.environ["AWS_SESSION_EXPIRATION"], "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=datetime.timezone.utc)

            actual_until_exp_seconds = int(
                exp.timestamp()
                - datetime.datetime.now(datetime.timezone.utc).timestamp()
            )

            until_exp_groups = re.search(r"(\d+(?=h))|(\d+(?=m))", until_exp)
            if until_exp_groups.group(1):
                until_exp = int(until_exp_groups.group(1))
                log.info(
                    f'Test(s) require atleast: {until_exp} hour{"s"[:until_exp^1]}'
                )
                diff_hours = int(
                    datetime.timedelta(seconds=actual_until_exp_seconds)
                    / datetime.timedelta(hours=1)
                )
                log.info(
                    f'Time until expiration: {diff_hours} hour{"s"[:diff_hours^1]}'
                )
                until_exp_seconds = until_exp * 60 * 60
            elif until_exp_groups.group(2):
                until_exp = int(until_exp_groups.group(2))
                log.info(
                    f'Test(s) require atleast: {until_exp} minute{"s"[:until_exp^1]}'
                )
                diff_minutes = datetime.timedelta(
                    seconds=actual_until_exp_seconds
                ) // datetime.timedelta(minutes=1)
                log.info(
                    f'Time until expiration: {diff_minutes} minute{"s"[:diff_minutes^1]}'
                )
                until_exp_seconds = until_exp * 60

            log.debug(f"Actual seconds until expiration: {actual_until_exp_seconds}")
            log.debug(f"Required seconds until expiration: {until_exp_seconds}")
            if actual_until_exp_seconds < until_exp_seconds:
                pytest.skip(
                    "AWS session token needs to be refreshed before running tests"
                )
        else:
            log.info("$AWS_SESSION_EXPIRATION is not set -- skipping check")
    else:
        log.info("Neither --until-aws-exp nor $UNTIL_AWS_EXP was set -- skipping check")


@timeout_decorator.timeout(30)
@pytest.fixture(scope="session")
def setup_metadb():
    """Creates `account_dim` and `executions` table"""
    log.info("Creating metadb tables")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        with open(
            f"{os.path.dirname(os.path.realpath(__file__))}/../sql/create_metadb_tables.sql",
            "r",
        ) as f:
            cur.execute(
                f.read()
                .replace("$", "")
                .format(
                    metadb_schema="testing",
                    metadb_name=os.environ["PGDATABASE"],
                )
            )
    yield None

    log.info("Dropping metadb tables")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS executions, account_dim")


@pytest.fixture(scope="function")
def truncate_executions(setup_metadb):
    """Removes all rows from execution table after every test"""

    yield None

    log.info("Teardown: Truncating executions table")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute("TRUNCATE executions")


@pytest.fixture(scope="function")
def aws_credentials():
    """
    Mocked AWS credentials needed to be set before importing Lambda Functions that define global boto3 clients.
    This prevents the region_name not specified errors.
    """
    os.environ["AWS_ACCESS_KEY_ID"] = os.environ.get("AWS_ACCESS_KEY_ID", "testing")
    os.environ["AWS_SECRET_ACCESS_KEY"] = os.environ.get(
        "AWS_SECRET_ACCESS_KEY", "testing"
    )
    os.environ["AWS_SECURITY_TOKEN"] = os.environ.get("AWS_SECURITY_TOKEN", "testing")
    os.environ["AWS_SESSION_TOKEN"] = os.environ.get("AWS_SESSION_TOKEN", "testing")
    os.environ["AWS_REGION"] = os.environ.get("AWS_REGION", "us-west-2")
    os.environ["AWS_DEFAULT_REGION"] = os.environ.get("AWS_DEFAULT_REGION", "us-west-2")


@pytest.fixture(scope="module")
def repo(request):
    log.info(f"Creating repo from template: {request.param}")
    repo = gh.get_repo(request.param)
    repo = gh.get_user().create_repo_from_template(
        "test-infra-live-" + str(uuid.uuid4()), repo
    )
    # needs to wait or else raises error on empty repo
    time.sleep(5)
    repo.edit(default_branch="master")

    yield repo

    log.info(f"Deleting repo: {request.param}")
    repo.delete()


@pytest.fixture
def pr(repo, request):
    """
    Creates the PR used for testing the function calls to the GitHub API.
    Current implementation creates all PR changes within one commit.
    """

    param = request.param
    base_commit_id = repo.get_branch(param["base_ref"]).commit.sha
    head_commit_id = push(repo, param["head_ref"], param["changes"])

    log.info("Creating PR")
    pr = repo.create_pull(
        title=param.get("title", f"test-{param['head_ref']}"),
        body=param.get("body", "Test PR"),
        base=param["base_ref"],
        head=param["head_ref"],
    )

    yield {
        "full_name": repo.full_name,
        "number": pr.number,
        "base_commit_id": base_commit_id,
        "head_commit_id": head_commit_id,
        "base_ref": param["base_ref"],
        "head_ref": param["head_ref"],
    }

    log.info(f"Removing PR head ref branch: {param['head_ref']}")
    repo.get_git_ref(f"heads/{param['head_ref']}").delete()

    log.info(f"Closing PR: #{pr.number}")
    try:
        pr.edit(state="closed")
    except Exception:
        log.info("PR is merged or already closed")


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
def tfvars_files(
    tmp_path_factory, docker_ecs_task, docker_lambda_receiver
) -> List[str]:
    """Returns list of tfvars json files to be used for Terraform variables"""
    parent = tmp_path_factory.mktemp("tfvars")
    secret_env_vars = {
        "registry_password": os.environ.get("REGISTRY_PASSWORD"),
        "github_token_ssm_value": os.environ.get("GITHUB_TOKEN"),
    }

    if os.environ.get("IS_REMOTE", False):
        secret_env_vars["approval_request_sender_email"] = os.environ[
            "APPROVAL_REQUEST_SENDER_EMAIL"
        ]
        secret_env_vars["approval_recipient_emails"] = [
            os.environ["APPROVAL_RECIPIENT_EMAIL"]
        ]
        env_vars = {}
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

    secret_filepath = parent / "secret.auto.tfvars.json"
    with secret_filepath.open("w", encoding="utf-8") as f:
        json.dump(secret_env_vars, f, indent=4, sort_keys=True)

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
        tfdir=os.path.join(FILE_DIR, "fixtures/terraform/mut/basic"),
        enable_cache=True,
        cache_dir=cache_dir,
    )

    tf.setup(cleanup_on_exit=False, extra_files=tfvars_files, use_cache=True)

    log.debug("Running terraform apply")
    try:
        tf.apply(auto_approve=True, use_cache=True)
    except TerraformTestError as err:
        log.debug(err, exc_info=True)
        pytest.skip("terraform apply failed")

    yield tf.output(use_cache=True)

    # log.debug("Running terraform destroy")
    # tf.destroy(auto_approve=True)
