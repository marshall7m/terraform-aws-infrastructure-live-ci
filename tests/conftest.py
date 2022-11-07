import pytest
import os
import datetime
import re
import logging
import time
import uuid

import github
import timeout_decorator
import aurora_data_api

from tests.helpers.utils import rds_data_client, terra_version, commit

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)


def pytest_addoption(parser):
    parser.addoption(
        "--until-aws-exp",
        action="store",
        default=os.environ.get("UNTIL_AWS_EXP", False),
        help="The least amount of time until the AWS session token expires in minutes (e.g. 10m) or hours (e.g. 2h)",
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


@pytest.fixture(scope="session")
def terraform_version(request):
    """Terraform version that will be installed and used"""
    terra_version("terraform", request.param, overwrite=True)
    return request.param


@pytest.fixture(scope="session")
def terragrunt_version(request):
    """Terragrunt version that will be installed and used"""
    terra_version("terragrunt", request.param, overwrite=True)
    return request.param


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
    base_commit = repo.get_branch(param["base_ref"])
    base_commit_id = base_commit.commit.sha
    head_ref = repo.create_git_ref(
        ref="refs/heads/" + param["head_ref"], sha=base_commit_id
    )
    commit_id = commit(
        repo,
        param["head_ref"],
        param["changes"],
        param.get("commit_message", "test commit"),
    ).sha
    head_ref.edit(sha=commit_id)

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
        "head_commit_id": commit_id,
        "base_ref": param["base_ref"],
        "head_ref": param["head_ref"],
    }

    log.info(f"Removing PR head ref branch: {param['head_ref']}")
    head_ref.delete()

    log.info(f"Closing PR: #{pr.number}")
    try:
        pr.edit(state="closed")
    except Exception:
        log.info("PR is merged or already closed")
