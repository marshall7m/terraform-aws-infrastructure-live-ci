import os
import logging
from unittest.mock import patch

import pytest
import aurora_data_api
import boto3
from moto import mock_stepfunctions

from tests.helpers.utils import insert_records, rds_data_client
from functions.trigger_sf import lambda_function

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.mark.usefixtures("aws_credentials", "truncate_executions")
def test_execution_finished_update_status():
    execution_id = "run-123"
    expected_status = "success"
    records = [{"execution_id": execution_id, "status": "running"}]
    records = insert_records("executions", records, enable_defaults=True)

    execution = lambda_function.ExecutionFinished(
        execution_id=execution_id,
        status=expected_status,
        is_rollback="false",
        commit_id="mock-commit",
        cfg_path="/foo",
    )
    execution.update_status()

    log.info("Assert finished execution record status was updated")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT status
            FROM executions
            WHERE execution_id = '{}'
            """.format(
                execution_id
            )
        )
        actual_status = cur.fetchone()[0]

    assert actual_status == expected_status


@pytest.mark.usefixtures("truncate_executions")
def test_abort_commit_records():
    commit_id = "test-commit"
    records = [
        {
            "execution_id": "run-bar",
            "account_name": "dev",
            "cfg_path": "dev/bar",
            "status": "running",
            "is_rollback": False,
            "commit_id": commit_id,
        },
        {
            "execution_id": "run-foo",
            "status": "waiting",
            "is_rollback": False,
            "commit_id": commit_id,
            "cfg_path": "dev/foo",
        },
        {
            "execution_id": "run-baz",
            "status": "success",
            "is_rollback": False,
            "commit_id": commit_id,
            "cfg_path": "dev/baz",
        },
    ]
    insert_records("executions", records, enable_defaults=True)

    execution = lambda_function.ExecutionFinished(
        execution_id="run-123",
        status="failed",
        is_rollback="false",
        commit_id=commit_id,
        cfg_path="/foo",
    )
    execution.abort_commit_records()

    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT execution_id
            FROM executions
            WHERE commit_id = '{}'
            AND "status" IN ('waiting', 'running')
        """.format(
                commit_id
            )
        )
        in_progress_ids = [val[0] for val in cur.fetchall() if val[0] is not None]

        log.info("Assert no execution has a waiting or running status")
        assert len(in_progress_ids) == 0


@mock_stepfunctions
def test_abort_sf_executions():
    execution_id = "run-123"
    sf = boto3.client("stepfunctions")

    machine_arn = sf.create_state_machine(
        name="mock-machine",
        definition="string",
        roleArn="arn:aws:iam::123456789012:role/machine-role",
    )["stateMachineArn"]

    execution_arn = sf.start_execution(stateMachineArn=machine_arn, name=execution_id)[
        "executionArn"
    ]

    execution = lambda_function.ExecutionFinished(
        execution_id=execution_id,
        status="failed",
        is_rollback="false",
        commit_id="mock-commit",
        cfg_path="/foo",
    )

    with patch.dict(os.environ, {"STATE_MACHINE_ARN": machine_arn}):
        # TODO: figure out how mock sf client with moto client to allow module-scope client in lambda file
        with patch("boto3.client") as mock_sf:
            mock_sf.return_value = sf
            execution.abort_sf_executions([execution_id])

    assert sf.describe_execution(executionArn=execution_arn)["status"] == "ABORTED"


@pytest.mark.usefixtures("aws_credentials", "truncate_executions")
def test_create_rollback_records():
    commit_id = "test-commit"
    expected_rollback_cfg_paths = ["dev/bar"]
    records = [
        {
            "execution_id": "run-bar",
            "account_name": "dev",
            "cfg_path": expected_rollback_cfg_paths[0],
            "status": "succeeded",
            "is_rollback": False,
            "commit_id": commit_id,
            "new_providers": ["hashicorp/null"],
            "new_resources": ["null_resource.this"],
        },
        {
            "execution_id": "run-foo",
            "status": "running",
            "is_rollback": False,
            "commit_id": commit_id,
            "cfg_path": "dev/foo",
        },
    ]
    insert_records("executions", records, enable_defaults=True)

    execution = lambda_function.ExecutionFinished(
        execution_id="run-123",
        status="failed",
        is_rollback="false",
        commit_id=commit_id,
        cfg_path="/foo",
    )
    execution.create_rollback_records()

    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT cfg_path
            FROM executions
            WHERE commit_id = '{}'
            AND is_rollback = true
        """.format(
                commit_id
            )
        )
        actual = [val[0] for val in cur.fetchall()]

        log.info("Assert rollback execution records were created")
        for path in expected_rollback_cfg_paths:
            assert path in actual


def test_handle_failed_execution_is_rollback():
    execution = lambda_function.ExecutionFinished(
        execution_id="run-123",
        status="failed",
        is_rollback="true",
        commit_id="mock-commit",
        cfg_path="/foo",
    )

    with pytest.raises(lambda_function.ClientException):
        execution.handle_failed_execution()


@patch.dict(os.environ, {"STATE_MACHINE_ARN": "mock"})
@pytest.mark.usefixtures("aws_credentials", "truncate_executions")
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
@pytest.mark.usefixtures("aws_credentials", "truncate_executions")
@patch("functions.trigger_sf.lambda_function.sf")
def test_start_executions(mock_sf, records, expected_running_ids):
    """Test to ensure that the Lambda Function handles account and directory level dependencies before starting any Step Function executions"""

    records = insert_records("executions", records, enable_defaults=True)

    lambda_function.start_sf_executions()

    log.info("Assert started Step Function execution statuses were updated to running")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute("SELECT execution_id FROM executions WHERE status = 'running'")
        res = cur.fetchall()
    res = [record[0] for record in res]
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
@pytest.mark.usefixtures("aws_credentials", "truncate_executions")
@patch.dict(
    os.environ,
    {
        "COMMIT_STATUS_CONFIG_SSM_KEY": "mock-ssm-config-key",
        "STATE_MACHINE_ARN": "mock",
        "GITHUB_MERGE_LOCK_SSM_KEY": "mock-ssm-key",
    },
)
def test_merge_lock(mock_ssm, records, expect_unlocked_merge_lock):
    """Test to ensure that the AWS System Manager Parameter Store merge lock value was reset to none if all executions within the metadb are finished"""
    from functions.trigger_sf.lambda_function import lambda_handler

    records = insert_records("executions", records, enable_defaults=True)

    lambda_handler({}, {})
    log.info("Assert merge lock value")
    if expect_unlocked_merge_lock:
        assert mock_ssm.put_parameter.called_once_with(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value="none",
            Type="String",
            Overwrite=True,
        )
