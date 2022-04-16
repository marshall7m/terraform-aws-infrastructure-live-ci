import pytest
import psycopg2
from psycopg2 import sql
from unittest.mock import patch
import os
import logging
import sys
import shutil
import uuid
import json
from pprint import pformat
import timeout_decorator
import sys

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@patch('functions.trigger_sf.lambda_function.sf')
@patch.dict(os.environ, {"METADB_CLUSTER_ARN": "mock","METADB_SECRET_ARN": "mock", "METADB_NAME": "mock", "STATE_MACHINE_ARN": "mock", 'GITHUB_MERGE_LOCK_SSM_KEY': 'mock-ssm-key'}, clear=True)
@pytest.mark.usefixtures('aws_credentials')
@pytest.mark.parametrize('records,execution,expected_aborted_ids,expected_rollback_cfg_paths', [
    (
        [
            {
                'execution_id': 'run-foo',
                'status': 'running',
                'is_rollback': False,
                'commit_id': 'test-commit'
            }
        ],
        {
            'execution_id': 'run-foo',
            'status': 'succeeded',
            'is_rollback': False,
            'commit_id': 'test-commit'
        },
        [],
        []
    ),
    (
        [
            {
                'execution_id': 'run-bar',
                'status': 'waiting',
                'is_rollback': False,
                'commit_id': 'test-commit'
            },
            {
                'execution_id': 'run-foo',
                'status': 'running',
                'is_rollback': False,
                'commit_id': 'test-commit'
            }
        ],
        {
            'execution_id': 'run-foo',
            'status': 'failed',
            'is_rollback': False,
            'commit_id': 'test-commit'
        },
        ['run-bar'],
        []
    ),
    (
        [
            {
                'execution_id': 'run-bar',
                'account_name': 'dev',
                'cfg_path': 'dev/bar',
                'status': 'succeeded',
                'is_rollback': False,
                'commit_id': 'test-commit',
                'new_providers': ['hashicorp/null'],
                'new_resources': ['null_resource.this']
            },
            {
                'execution_id': 'run-foo',
                'status': 'running',
                'is_rollback': False,
                'commit_id': 'test-commit'
            }
        ],
        {
            'execution_id': 'run-foo',
            'status': 'failed',
            'is_rollback': False,
            'commit_id': 'test-commit'
        },
        [],
        ['dev/bar']
    )
])
def test__execution_finished_status_update(mock_client, cur, conn, records, execution, expected_aborted_ids, expected_rollback_cfg_paths, insert_records):
    from functions.trigger_sf import lambda_function
    cur = conn.cursor()
    mock_client.list_executions.return_value = {'executions': [{'name': record['execution_id'], 'executionArn': 'mock-arn'} for record in records if record['status'] != 'waiting']}
    mock_client.stop_execution.return_value = None
    records = insert_records('executions', records, enable_defaults=True)

    response = lambda_function._execution_finished(cur, execution)

    log.info('Assert finished execution record status was updated')
    cur.execute(sql.SQL('SELECT status FROM executions WHERE execution_id = {}').format(sql.Literal(execution['execution_id'])))
    assert execution['status'] == cur.fetchone()[0]

    log.info('Assert Step Function executions were aborted')
    cur.execute(sql.SQL("SELECT execution_id FROM executions WHERE commit_id = {} AND status = 'aborted'").format(sql.Literal(execution['commit_id'])))
    res = [val[0] for val in cur.fetchall()]
    log.debug(f'Actual: {res}')
    assert all(path in res for path in expected_aborted_ids) == True 

    log.info('Assert rollback execution records were created')
    cur.execute(sql.SQL("SELECT cfg_path FROM executions WHERE commit_id = {} AND is_rollback = true").format(sql.Literal(execution['commit_id'])))
    res = [val[0] for val in cur.fetchall()]
    log.debug(f'Actual: {res}')
    assert all(path in res for path in expected_rollback_cfg_paths) == True 

@pytest.mark.skip(msg='Not implemented')
@patch('functions.trigger_sf.lambda_function.sf')
@patch.dict(os.environ, {"METADB_CLUSTER_ARN": "mock","METADB_SECRET_ARN": "mock", "METADB_NAME": "mock", "STATE_MACHINE_ARN": "mock", 'GITHUB_MERGE_LOCK_SSM_KEY': 'mock-ssm-key'}, clear=True)
@pytest.mark.usefixtures('mock_conn', 'aws_credentials')
@patch('functions.trigger_sf.lambda_function.ssm')
def test__start_executions(merge_lock, expected_merge_lock, expected_running_ids):
    log.info('Assert Step Function executions were started with approriate input')
    log.info('Assert started Step Function execution statuses were updated to running')

    log.info('Assert merge lock value was resetted')

# ids = ['test_failed_rollback', 'test_failed_execution', 'test_multiple_commmits_waiting']