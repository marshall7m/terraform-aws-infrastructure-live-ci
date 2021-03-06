from functions.webhook_receiver.lambda_function import ServerException
import pytest
import os
import logging
import sys
from subprocess import CalledProcessError
import json
from unittest.mock import patch, call
from tests.helpers.utils import null_provider_resource, insert_records

# adds ecs src to PATH
# prevents import errs within src files that are caused by src import paths being relative to it's own setup
sys.path.append(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__))))
    + "/docker/src"
)
from docker.src.terra_run.run import (  # noqa: E402
    update_new_resources,
    get_new_provider_resources,
    main,
)  # noqa: E402
from docker.src.common.utils import subprocess_run  # noqa: E402
from tests.unit.docker.conftest import mock_subprocess_run  # noqa: E402
from psycopg2 import sql  # noqa: E402

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture(autouse=True)
def git_repo_cwd(git_repo):
    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse("--show-toplevel")
    os.chdir(git_root)
    return git_root


@patch.dict(
    os.environ,
    {
        "TG_BACKEND": "local",
        "NEW_PROVIDERS": '["test-provider"]',
        "IS_ROLLBACK": "false",
        "ROLE_ARN": "tf-role-arn",
    },
)
@patch(
    "docker.src.terra_run.run.subprocess_run",
    side_effect=mock_subprocess_run,
)
@pytest.mark.usefixtures("terraform_version", "terragrunt_version")
@pytest.mark.parametrize(
    "repo_changes,new_providers,expected",
    [
        pytest.param(
            {
                "directory_dependency/dev-account/us-west-2/env-one/doo/a.tf": null_provider_resource
            },
            ["registry.terraform.io/hashicorp/null"],
            ["null_resource.this"],
            id="new_resource_exists",
        ),
        pytest.param(
            {"directory_dependency/dev-account/us-west-2/env-one/doo/a.tf": ""},
            ["registry.terraform.io/hashicorp/null"],
            [],
            id="new_resource_not_exists",
        ),
    ],
    indirect=["repo_changes"],
)
def test_get_new_provider_resources(mock_run, repo_changes, new_providers, expected):
    target_path = os.path.dirname(list(repo_changes.keys())[0])
    log.info("Terraform applying repo changes to update Terraform state file")
    subprocess_run(
        f"terragrunt apply --terragrunt-working-dir {target_path} -auto-approve"
    )

    actual = get_new_provider_resources(target_path, new_providers)

    assert actual == expected


@patch.dict(
    os.environ,
    {
        "METADB_CLUSTER_ARN": "mock",
        "METADB_SECRET_ARN": "mock",
        "METADB_NAME": "mock",
        "TG_BACKEND": "local",
        "EXECUTION_ID": "test-id",
        "TG_COMMAND": "",
        "CFG_PATH": "test/dir",
        "NEW_PROVIDERS": '["test-provider"]',
        "IS_ROLLBACK": "false",
        "ROLE_ARN": "tf-role-arn",
    },
)
@patch("docker.src.terra_run.run.get_new_provider_resources")
@pytest.mark.usefixtures("mock_conn", "aws_credentials", "truncate_executions")
@pytest.mark.parametrize(
    "resources",
    [
        pytest.param(["test.this"], id="one_resource"),
        pytest.param(["test.this", "test.that"], id="multiple_resources"),
        pytest.param([], id="no_resources"),
    ],
)
def test_update_new_resources(mock_get_new_provider_resources, conn, resources):
    """Assert that the expected new_resources value is within the associated record"""

    insert_records(
        conn,
        "executions",
        [{"execution_id": os.environ["EXECUTION_ID"]}],
        enable_defaults=True,
    )

    mock_get_new_provider_resources.return_value = resources

    update_new_resources()

    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
        SELECT new_resources
        FROM executions
        WHERE execution_id = {}
        """
            ).format(sql.Literal(os.environ["EXECUTION_ID"]))
        )

        res = cur.fetchall()[0][0]
        log.debug(f"Results:\n{res}")

    log.info(
        "Assert that the expected new_resources value is within the associated record"
    )
    assert res == resources


@pytest.mark.parametrize(
    "state_name,expected_status,run_side_effect,update_new_resources_side_effect",
    [
        pytest.param("Plan", "success", None, None, id="plan_run_succeed"),
        pytest.param("Apply", "success", None, None, id="all_succeed"),
        pytest.param(
            "Apply",
            "failure",
            CalledProcessError(1, ""),
            None,
            id="update_resources_failed",
        ),
        pytest.param(
            "Apply",
            "failure",
            CalledProcessError(1, ""),
            ServerException("Function failed"),
            id="all_failed",
        ),
    ],
)
@patch.dict(
    os.environ,
    {
        "TG_COMMAND": "",
        "COMMIT_STATUS_CONFIG": json.dumps({"Plan": True, "Apply": True}),
    },
)
@patch("docker.src.terra_run.run.send_commit_status")
@patch("docker.src.terra_run.run.update_new_resources")
@patch("subprocess.run")
def test_main(
    mock_subprocess,
    mock_update_new_resources,
    mock_send_commit_status,
    state_name,
    expected_status,
    run_side_effect,
    update_new_resources_side_effect,
):
    """Ensures that the correct commit status state is sent depending on the results of upstream processes"""
    os.environ["STATE_NAME"] = state_name

    mock_subprocess.side_effect = run_side_effect
    mock_update_new_resources.side_effect = update_new_resources_side_effect

    main()
    assert mock_send_commit_status.call_args_list == [call(expected_status)]
