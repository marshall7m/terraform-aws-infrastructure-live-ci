import pytest
import os
import logging
import sys
import json
from unittest.mock import patch
from pprint import pformat
from tests.helpers.utils import insert_records, local_execute
from functions.approval_response.lambda_function import App, ClientException
from contextlib import nullcontext as does_not_raise

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


voter = "voter-foo"
task_token = "token-123"
execution_id = "run-123"


@pytest.mark.parametrize(
    "action,status,record,expectation,expect_send_task_token",
    [
        pytest.param(
            "approve",
            "RUNNING",
            {
                "execution_id": execution_id,
                "min_approval_count": 1,
                "approval_voters": [],
            },
            does_not_raise(),
            True,
            id="approval_met",
        ),
        pytest.param(
            "approve",
            "RUNNING",
            {
                "execution_id": execution_id,
                "min_approval_count": 2,
                "approval_voters": [],
            },
            does_not_raise(),
            False,
            id="approval_not_met",
        ),
        pytest.param(
            "approve",
            "RUNNING",
            {
                "execution_id": execution_id,
                "min_approval_count": 1,
                "approval_voters": [],
                "rejection_voters": [voter],
            },
            does_not_raise(),
            False,
            id="update_vote_to_approval",
        ),
        pytest.param(
            "approve",
            "ABORTED",
            {},
            pytest.raises(ClientException),
            False,
            id="not_running",
        ),
        pytest.param(
            "approve",
            "RUNNING",
            {},
            pytest.raises(ClientException),
            False,
            id="record_not_exists",
        ),
    ],
)
@patch.dict(
    os.environ,
    {"METADB_CLUSTER_ARN": "mock", "METADB_SECRET_ARN": "mock", "METADB_NAME": "mock"},
)
@pytest.mark.usefixtures("mock_conn", "aws_credentials", "truncate_executions")
@patch("boto3.client")
def test_update_vote(
    mock_boto_client,
    action,
    status,
    record,
    expectation,
    expect_send_task_token,
):
    mock_boto_client.return_value = mock_boto_client
    mock_boto_client.describe_execution.return_value = {
        "status": status,
        "name": "run-123",
    }

    if record != {}:
        log.info("Creating test record")
        record = insert_records("executions", record, enable_defaults=True)
        log.info(f"Record: {pformat(record)}")

    app = App()

    with expectation:
        response = app.update_vote(execution_id, action, voter, task_token)
        log.debug(f"Response:\n{response}")

    if record != {}:
        log.info("Assert record's approriate voters list contains the recipient")
        res = local_execute(
            """
                SELECT approval_voters, rejection_voters
                FROM executions
                WHERE execution_id = {}
            """.format(
                execution_id
            ),
            fetch_one=True,
            return_dict=True,
        )

        if action == "approve":
            assert voter in res["approval_voters"]
            assert voter not in res["rejection_voters"]

        elif action == "reject":
            assert voter in res["rejection_voters"]
            assert voter not in res["approval_voters"]

    if expect_send_task_token:
        mock_boto_client.send_task_success.assert_called_with(
            taskToken=task_token,
            output=json.dumps(action),
        )
