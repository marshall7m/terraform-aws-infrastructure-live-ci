import pytest
import os
import logging
import sys
import json
from unittest.mock import patch
from pprint import pformat
from tests.helpers.utils import insert_records
from psycopg2 import sql

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)


def lambda_handler(event=None, context=None):
    """Imports Lambda function after boto3 client patch has been created to prevent boto3 region_name not specified error"""
    from functions.approval_response.lambda_function import lambda_handler

    return lambda_handler(event, context)


@pytest.mark.parametrize(
    "event,record,status,expected_status_code,expected_send_token",
    [
        pytest.param(
            {
                "body": {"action": "approve", "recipient": "test-user"},
                "query": {
                    "ex": "mock-run",
                    "exId": "mock-arn",
                    "taskToken": "mock-token",
                },
            },
            {
                "execution_id": "mock-run",
                "min_approval_count": 1,
                "approval_voters": [],
            },
            "RUNNING",
            302,
            True,
            id="approval_met",
        ),
        pytest.param(
            {
                "body": {"action": "approve", "recipient": "test-user"},
                "query": {
                    "ex": "mock-run",
                    "exId": "mock-arn",
                    "taskToken": "mock-token",
                },
            },
            {
                "execution_id": "mock-run",
                "min_approval_count": 2,
                "approval_voters": [],
            },
            "RUNNING",
            302,
            False,
            id="approval_not_met",
        ),
        pytest.param(
            {
                "body": {"action": "approve", "recipient": "test-user"},
                "query": {
                    "ex": "mock-run",
                    "exId": "mock-arn",
                    "taskToken": "mock-token",
                },
            },
            {
                "execution_id": "mock-run",
                "min_approval_count": 1,
                "approval_voters": [],
                "rejection_voters": ["test-user"],
            },
            "RUNNING",
            302,
            False,
            id="update_vote_to_approval",
        ),
        pytest.param(
            {
                "body": {"action": "approve", "recipient": "test-user"},
                "query": {
                    "ex": "mock-run",
                    "exId": "mock-arn",
                    "taskToken": "mock-token",
                },
            },
            {},
            "ABORTED",
            410,
            False,
            id="not_running",
        ),
        pytest.param(
            {
                "body": {"action": "approve", "recipient": "test-user"},
                "query": {
                    "ex": "mock-run",
                    "exId": "mock-arn",
                    "taskToken": "mock-token",
                },
            },
            {},
            "RUNNING",
            500,
            False,
            id="record_not_exists",
        ),
    ],
)
@patch("functions.approval_response.lambda_function.sf")
@patch.dict(
    os.environ,
    {"METADB_CLUSTER_ARN": "mock", "METADB_SECRET_ARN": "mock", "METADB_NAME": "mock"},
    clear=True,
)
@pytest.mark.usefixtures("mock_conn", "aws_credentials", "truncate_executions")
def test_lambda_handler(
    mock_sf, conn, cur, event, record, status, expected_status_code, expected_send_token
):
    mock_sf.describe_execution.return_value = {"status": status}

    if record != {}:
        log.info("Creating test record")
        record = insert_records(conn, "executions", record, enable_defaults=True)
        log.info(f"Record: {pformat(record)}")

    log.info("Running Lambda Function")
    response = lambda_handler(event, {})

    assert response["statusCode"] == expected_status_code

    if record != {}:
        log.info("Assert record's approriate voters list contains the recipient")
        cur.execute(
            sql.SQL(
                "SELECT approval_voters, rejection_voters FROM executions WHERE execution_id = {}"
            ).format(sql.Literal(event["query"]["ex"]))
        )
        res = dict(cur.fetchone())

        if event["body"]["action"] == "approve":
            assert event["body"]["recipient"] in res["approval_voters"]
            assert event["body"]["recipient"] not in res["rejection_voters"]
        elif event["body"]["action"] == "reject":
            assert event["body"]["recipient"] in res["rejection_voters"]
            assert event["body"]["recipient"] not in res["approval_voters"]

    if expected_send_token:
        mock_sf.send_task_success.assert_called_with(
            taskToken=event["query"]["taskToken"],
            output=json.dumps(event["body"]["action"]),
        )
