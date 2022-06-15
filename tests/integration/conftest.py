from time import sleep
import pytest
import os
import boto3
import github
import logging
import aurora_data_api
import git
from tests.helpers.utils import check_ses_sender_email_auth
import datetime
import re

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_addoption(parser):
    parser.addoption(
        "--skip-truncate", action="store_true", help="skips truncating execution table"
    )

    parser.addoption(
        "--until-aws-exp",
        action="store",
        default=os.environ.get("UNTIL_AWS_EXP", False),
        help="The least amount of time until the AWS session token expires in minutes (e.g. 10m) or hours (e.g. 2h)",
    )


def pytest_generate_tests(metafunc):
    if metafunc.config.getoption("skip_truncate"):
        metafunc.parametrize(
            "truncate_executions",
            [True],
            scope="session",
            ids=["skip_truncate"],
            indirect=True,
        )

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

    if hasattr(metafunc.cls, "case"):
        if "target_execution" in metafunc.fixturenames:
            # gets expected count of tf directories that will have their
            # new provider resources rolled back
            rollback_execution_count = len(
                [
                    1
                    for scenario in metafunc.cls.case["executions"].values()
                    if scenario.get("actions", {}).get("rollback_providers", None)
                    is not None
                ]
            )
            # parameterizes tests/fixtures with the range of expected tf directories
            # that should be setup and tested
            target_execution_count = (
                len(metafunc.cls.case["executions"]) + rollback_execution_count
            )
            metafunc.parametrize(
                "target_execution",
                list(range(0, target_execution_count)),
                scope="class",
            )

            metafunc.cls.executions = [{} for _ in range(0, target_execution_count)]


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


@pytest.fixture(scope="session", autouse=True)
def verify_ses_sender_email(aws_session_expiration_check):
    if check_ses_sender_email_auth(
        os.environ["TF_VAR_approval_request_sender_email"], send_verify_email=True
    ):
        log.info(
            f'Testing sender email address is verified: {os.environ["TF_VAR_approval_request_sender_email"]}'
        )
    else:
        pytest.skip(
            f'Testing sender email address is not verified: {os.environ["TF_VAR_approval_request_sender_email"]}'
        )


@pytest.fixture(scope="session")
def tf(tf_factory):
    # using tf_factory() instead parametrizing terra-fixt's tf() fixture via pytest_generate_tests()
    # since pytest_generate_tests() parametrization causes the session, module and class scoped fixture teardowns
    # to be called after every test that uses the tf fixture
    yield tf_factory(f"{os.path.dirname(os.path.realpath(__file__))}/fixtures")


@pytest.fixture(scope="session")
def mut_plan(tf):
    log.info("Getting tf plan")
    yield tf.plan(output=True)


@pytest.fixture(scope="session")
def mut_output(tf):
    log.info("Applying testing tf module")
    tf.apply(auto_approve=True)

    yield {k: v["value"] for k, v in tf.output().items()}


@pytest.fixture(scope="module")
def gh():
    return github.Github(os.environ["TF_VAR_testing_integration_github_token"], retry=3)


@pytest.fixture(scope="module")
def repo(gh, mut_output):
    repo = gh.get_user().get_repo(mut_output["repo_name"])
    os.environ["REPO_FULL_NAME"] = repo.full_name

    return repo


@pytest.fixture(scope="module")
def git_repo(tmp_path_factory):
    dir = str(tmp_path_factory.mktemp("scenario-repo-"))
    log.debug(f"Scenario repo dir: {dir}")

    repo = git.Repo.clone_from(
        f'https://oauth2:{os.environ["TF_VAR_testing_integration_github_token"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git',
        dir,
    )

    log.info("Configuring user-level git identity")
    repo.config_writer(config_level="global").set_value(
        "user", "name", os.environ.get("GIT_CONFIG_USER", "integration-testing-user")
    ).release()
    repo.config_writer(config_level="global").set_value(
        "user",
        "email",
        os.environ.get("GIT_CONFIG_EMAIL", "integration-testing-user@testing.com"),
    ).release()

    return repo


@pytest.fixture(scope="module")
def merge_pr(repo, git_repo, mut_output):

    merge_commits = {}

    def _merge(base_ref=None, head_ref=None):
        if base_ref is not None and head_ref is not None:
            log.info("Merging PR")
            merge_commits[head_ref] = repo.merge(base_ref, head_ref)

        return merge_commits

    yield _merge

    log.info(f'Removing PR changes from base branch: {mut_output["base_branch"]}')

    log.debug("Pulling remote changes")
    git_repo.git.reset("--hard")
    git_repo.git.pull()

    log.debug(
        "Removing admin enforcement from branch protection to allow revert pushes to trunk branch"
    )
    branch = repo.get_branch(branch=mut_output["base_branch"])
    branch.remove_admin_enforcement()

    log.debug("Removing required status checks")
    status_checks = branch.get_required_status_checks().contexts
    branch.edit_required_status_checks(contexts=[])
    current_status_checks = status_checks
    while len(current_status_checks) > 0:
        sleep(3)
        current_status_checks = branch.get_required_status_checks().contexts

    log.debug("Reverting all changes from testing PRs")
    try:
        for ref, commit in reversed(merge_commits.items()):
            log.debug(f"Merge Commit ID: {commit.sha}")

            git_repo.git.revert("-m", "1", "--no-commit", str(commit.sha))
            git_repo.git.commit(
                "-m", f"Revert changes from PR: {ref} within fixture teardown"
            )
            git_repo.git.push("origin", "--force")
    except Exception as e:
        raise e
    finally:
        log.debug("Adding admin enforcement back")
        branch.set_admin_enforcement()

        log.debug("Adding required status checks back")
        branch.edit_required_status_checks(contexts=status_checks)


@pytest.fixture(scope="session", autouse=True)
def setup_metadb_user(mut_output):
    log.info("Setting up testing metadb user")
    with aurora_data_api.connect(
        aurora_cluster_arn=mut_output["metadb_arn"],
        secret_arn=mut_output["metadb_secret_manager_master_arn"],
        database=mut_output["metadb_name"],
        # recommended for DDL statements
        continue_after_timeout=True,
    ) as conn:
        with conn.cursor() as cur:
            log.debug(f"Role: {mut_output['metadb_username']}")
            log.debug(f"Search path: {mut_output['metadb_schema']}")
            cur.execute(
                f"GRANT USAGE ON SCHEMA {mut_output['metadb_schema']} to {mut_output['metadb_username']}"
            )
            cur.execute(
                f"""
                ALTER ROLE CURRENT_USER SET search_path TO {mut_output['metadb_schema']};
                """
            )

            cur.execute("show search_path;")
            log.debug(f"Search path: {cur.fetchall()}")

            cur.execute(
                f"""
                SELECT tablename FROM pg_tables WHERE schemaname = '{mut_output['metadb_schema']}';
                """
            )

            log.debug(f"Tables within schema: {mut_output['metadb_schema']}")
            log.debug(cur.fetchall())


@pytest.fixture(scope="module", autouse=True)
def truncate_executions(request, mut_output):
    # table setup is within tf module
    # yielding none to define truncation as pytest teardown logic
    yield None
    if getattr(request, "param", False):
        log.info("Skip truncating execution table")
    else:
        log.info("Truncating executions table")
        with aurora_data_api.connect(
            aurora_cluster_arn=mut_output["metadb_arn"],
            secret_arn=mut_output["metadb_secret_manager_master_arn"],
            database=mut_output["metadb_name"],
            # recommended for DDL statements
            continue_after_timeout=True,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute("TRUNCATE executions")


@pytest.fixture(scope="module", autouse=True)
def reset_merge_lock_ssm_value(request, mut_output):
    ssm = boto3.client("ssm")
    log.info(f"Resetting merge lock SSM value for module: {request.fspath}")
    yield ssm.put_parameter(
        Name=mut_output["merge_lock_ssm_key"],
        Value="none",
        Type="String",
        Overwrite=True,
    )


@pytest.fixture(scope="module", autouse=True)
def abort_hanging_sf_executions(mut_output):
    yield None

    sf = boto3.client("stepfunctions")

    log.info("Stopping step function execution if left hanging")
    execution_arns = [
        execution["executionArn"]
        for execution in sf.list_executions(
            stateMachineArn=mut_output["state_machine_arn"], statusFilter="RUNNING"
        )["executions"]
    ]

    for arn in execution_arns:
        log.debug(f"ARN: {arn}")

        sf.stop_execution(
            executionArn=arn,
            error="IntegrationTestsError",
            cause="Failed integrations tests prevented execution from finishing",
        )


@pytest.fixture(scope="module")
def cleanup_dummy_repo(gh, request):
    yield request.param
    try:
        log.info(f"Deleting dummy GitHub repo: {request.param}")
        gh.get_user().get_repo(request.param).delete()
    except github.UnknownObjectException:
        log.info("GitHub repo does not exist")
