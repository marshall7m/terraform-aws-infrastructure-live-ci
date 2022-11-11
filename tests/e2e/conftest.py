from time import sleep
import pytest
import os
import boto3
import github
import logging
import aurora_data_api
import git
from tests.helpers.utils import check_ses_sender_email_auth

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_generate_tests(metafunc):
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
def verify_ses_sender_email():
    if check_ses_sender_email_auth(
        os.environ.get("APPROVAL_REQUEST_SENDER_EMAIL"), send_verify_email=True
    ):
        log.info(
            f'Testing sender email address is verified: {os.environ["APPROVAL_REQUEST_SENDER_EMAIL"]}'
        )
    else:
        pytest.skip(
            f'Testing sender email address is not verified: {os.environ["APPROVAL_REQUEST_SENDER_EMAIL"]}'
        )


@pytest.fixture(scope="module")
def git_repo(tmp_path_factory):
    dir = str(tmp_path_factory.mktemp("scenario-repo-"))
    log.debug(f"Scenario repo dir: {dir}")

    repo = git.Repo.clone_from(
        f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git',
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
            cause="Failed tests prevented execution from finishing",
        )
