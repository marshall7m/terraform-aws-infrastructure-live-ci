import pytest
from psycopg2 import sql
from unittest.mock import patch
import os
import json
import logging
from tests.helpers.utils import insert_records
from functions.trigger_sf import lambda_function

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@patch.dict(
    os.environ,
    {
        "REPO_FULL_NAME": "user/repo",
        "AWS_REGION": "us-west-2",
        "GITHUB_TOKEN_SSM_KEY": "mock-ssm-token-key",
        "COMMIT_STATUS_CONFIG_SSM_KEY": "mock-ssm-config-key",
        "METADB_CLUSTER_ARN": "mock",
        "METADB_SECRET_ARN": "mock",
        "METADB_NAME": "mock",
        "STATE_MACHINE_ARN": "mock",
        "GITHUB_MERGE_LOCK_SSM_KEY": "mock-ssm-key",
    },
    clear=True,
)
@pytest.mark.usefixtures("aws_credentials", "truncate_executions")
@pytest.mark.parametrize(
    "records,execution,expected_aborted_ids,expected_rollback_cfg_paths",
    [
        pytest.param(
            [
                {
                    "execution_id": "run-foo",
                    "status": "running",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                }
            ],
            {
                "execution_id": "run-foo",
                "status": "succeeded",
                "is_rollback": False,
                "commit_id": "test-commit",
            },
            [],
            [],
            id="succeeded_execution",
        ),
        pytest.param(
            [
                {
                    "execution_id": "run-baz",
                    "account_name": "dev",
                    "cfg_path": "dev/baz",
                    "status": "succeeded",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                    "new_providers": [],
                    "new_resources": [],
                },
                {
                    "execution_id": "run-zoo",
                    "account_name": "dev",
                    "cfg_path": "dev/zoo",
                    "status": "running",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                    "new_providers": [],
                    "new_resources": [],
                },
                {
                    "execution_id": "run-bar",
                    "account_name": "dev",
                    "cfg_path": "dev/bar",
                    "status": "succeeded",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                    "new_providers": ["hashicorp/null"],
                    "new_resources": ["null_resource.this"],
                },
                {
                    "execution_id": "run-foo",
                    "status": "running",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                    "cfg_path": "dev/foo",
                },
            ],
            {
                "execution_id": "run-foo",
                "status": "failed",
                "is_rollback": False,
                "commit_id": "test-commit",
                "cfg_path": "dev/foo",
            },
            ["run-zoo"],
            ["dev/bar"],
            id="failed_execution",
        ),
        pytest.param(
            [
                {
                    "execution_id": "run-foo",
                    "status": "running",
                    "is_rollback": True,
                    "commit_id": "test-commit",
                }
            ],
            {
                "execution_id": "run-foo",
                "status": "failed",
                "is_rollback": True,
                "commit_id": "test-commit",
            },
            [],
            [],
            id="failed_rollback_execution",
        ),
    ],
)
@patch("requests.post")
@patch("functions.trigger_sf.lambda_function.ssm")
@patch("functions.trigger_sf.lambda_function.sf")
def test__execution_finished_status_update(
    mock_sf,
    mock_ssm,
    mock_post,
    cur,
    conn,
    records,
    execution,
    expected_aborted_ids,
    expected_rollback_cfg_paths,
):
    """
    Test to ensure that the finished execution's respective status was updated and
    the function handles all possible execution statuses.
    """
    mock_ssm.get_parameter.return_value = {
        "Parameter": {"Value": json.dumps({"Execution": True})}
    }

    cur = conn.cursor()
    mock_sf.list_executions.return_value = {
        "executions": [
            {"name": record["execution_id"], "executionArn": "mock-arn"}
            for record in records
            if record["status"] != "waiting"
        ]
    }
    mock_sf.stop_execution.return_value = None
    records = insert_records(conn, "executions", records, enable_defaults=True)

    try:
        lambda_function._execution_finished(cur, execution, 000000000000)
    except lambda_function.ClientException as e:
        # expects lambda to error if execution was a rollback and wasn't successful
        if not execution["is_rollback"] and execution["status"] not in [
            "aborted",
            "failed",
        ]:
            raise (e)

    log.info("Assert finished execution record status was updated")
    cur.execute(
        sql.SQL("SELECT status FROM executions WHERE execution_id = {}").format(
            sql.Literal(execution["execution_id"])
        )
    )
    assert execution["status"] == cur.fetchone()[0]

    log.info("Assert Step Function executions were aborted")
    cur.execute(
        sql.SQL(
            "SELECT execution_id FROM executions WHERE commit_id = {} AND status = 'aborted'"
        ).format(sql.Literal(execution["commit_id"]))
    )
    res = [val[0] for val in cur.fetchall()]
    log.debug(f"Actual: {res}")
    assert all(path in res for path in expected_aborted_ids) is True

    log.info("Assert rollback execution records were created")
    cur.execute(
        sql.SQL(
            "SELECT cfg_path FROM executions WHERE commit_id = {} AND is_rollback = true"
        ).format(sql.Literal(execution["commit_id"]))
    )
    res = [val[0] for val in cur.fetchall()]
    log.debug(f"Actual: {res}")
    assert all(path in res for path in expected_rollback_cfg_paths) is True


@patch("functions.trigger_sf.lambda_function.sf")
@patch.dict(
    os.environ,
    {
        "COMMIT_STATUS_CONFIG_SSM_KEY": "mock-ssm-config-key",
        "METADB_CLUSTER_ARN": "mock",
        "METADB_SECRET_ARN": "mock",
        "METADB_NAME": "mock",
        "STATE_MACHINE_ARN": "mock",
        "GITHUB_MERGE_LOCK_SSM_KEY": "mock-ssm-key",
    },
    clear=True,
)
@pytest.mark.usefixtures("mock_conn", "aws_credentials", "truncate_executions")
@pytest.mark.parametrize(
    "records,expected_running_ids",
    [
        pytest.param(
            [
                {
                    "execution_id": "run-foo",
                    "cfg_path": "dev/foo",
                    "cfg_deps": [],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
                {
                    "execution_id": "run-bar",
                    "cfg_path": "dev/bar",
                    "cfg_deps": ["dev/foo"],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
            ],
            ["run-foo"],
            id="no_deps_1_execution",
        ),
        pytest.param(
            [
                {
                    "execution_id": "run-foo",
                    "cfg_path": "dev/foo",
                    "cfg_deps": [],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "succeeded",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
                {
                    "execution_id": "run-bar",
                    "cfg_path": "dev/bar",
                    "cfg_deps": ["dev/foo"],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
                {
                    "execution_id": "run-zoo",
                    "cfg_path": "dev/zoo",
                    "cfg_deps": ["dev/foo"],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
            ],
            ["run-bar", "run-zoo"],
            id="succedded_deps_2_executions",
        ),
        pytest.param(
            [
                {
                    "execution_id": "run-foo",
                    "cfg_path": "dev/foo",
                    "cfg_deps": [],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "succeeded",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
                {
                    "execution_id": "run-bar",
                    "cfg_path": "dev/bar",
                    "cfg_deps": ["dev/foo"],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "failed",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
                {
                    "execution_id": "run-baz",
                    "cfg_path": "dev/baz",
                    "cfg_deps": ["dev/foo", "dev/bar"],
                    "account_name": "dev",
                    "account_deps": [],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
            ],
            [],
            id="failed_deps_0_executions",
        ),
        pytest.param(
            [
                {
                    "execution_id": "run-foo",
                    "cfg_path": "dev/foo",
                    "cfg_deps": [],
                    "account_name": "dev",
                    "account_deps": ["shared"],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
                {
                    "execution_id": "run-bar",
                    "cfg_path": "dev/bar",
                    "cfg_deps": ["dev/foo"],
                    "account_name": "dev",
                    "account_deps": ["shared"],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
                {
                    "execution_id": "run-doo",
                    "cfg_path": "shared/doo",
                    "cfg_deps": [],
                    "account_name": "shared",
                    "account_deps": [],
                    "status": "waiting",
                    "is_rollback": False,
                    "commit_id": "test-commit",
                },
            ],
            ["run-doo"],
            id="account_deps_1_execution",
        ),
    ],
)
def test__start_executions(mock_sf, conn, records, expected_running_ids):
    """Test to ensure that the Lambda Function handles account and directory level dependencies before starting any Step Function executions"""

    cur = conn.cursor()
    records = insert_records(conn, "executions", records, enable_defaults=True)

    lambda_function._start_sf_executions(cur)

    log.info("Assert started Step Function execution statuses were updated to running")
    cur.execute(sql.SQL("SELECT execution_id FROM executions WHERE status = 'running'"))
    res = [val[0] for val in cur.fetchall()]
    log.debug(f"Actual: {res}")
    assert all(path in res for path in expected_running_ids) is True

    log.info("Assert correct number of Step Function execution were started")
    assert mock_sf.start_execution.call_count == len(expected_running_ids)


@pytest.mark.parametrize(
    "records,expect_unlocked_merge_lock",
    [
        pytest.param(
            [{"execution_id": "run-foo", "status": "succeeded"}],
            True,
            id="unlocked_merge_lock",
        ),
        pytest.param(
            [{"execution_id": "run-foo", "status": "waiting"}],
            False,
            id="locked_merge_lock",
        ),
    ],
)
@patch("functions.trigger_sf.lambda_function.ssm")
@pytest.mark.usefixtures("mock_conn", "aws_credentials", "truncate_executions")
@patch.dict(
    os.environ,
    {
        "COMMIT_STATUS_CONFIG_SSM_KEY": "mock-ssm-config-key",
        "METADB_CLUSTER_ARN": "mock",
        "METADB_SECRET_ARN": "mock",
        "METADB_NAME": "mock",
        "STATE_MACHINE_ARN": "mock",
        "GITHUB_MERGE_LOCK_SSM_KEY": "mock-ssm-key",
    },
    clear=True,
)
def test_merge_lock(mock_ssm, conn, records, expect_unlocked_merge_lock):
    """Test to ensure that the AWS System Manager Parameter Store merge lock value was reset to none if all executions within the metadb are finished"""
    from functions.trigger_sf.lambda_function import lambda_handler

    records = insert_records(conn, "executions", records, enable_defaults=True)

    lambda_handler({}, {})
    log.info("Assert merge lock value")
    if expect_unlocked_merge_lock:
        assert mock_ssm.put_parameter.called_once_with(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value="none",
            Type="String",
            Overwrite=True,
        )
