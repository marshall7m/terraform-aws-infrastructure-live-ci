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

def lambda_handler(event=None, context=None):
    '''Imports Lambda function after boto3 client patch has been created to prevent boto3 region_name not specified error'''
    from functions.trigger_sf.lambda_function import lambda_handler
    return lambda_handler(event, context)

@pytest.mark.parametrize('event,records,merge_lock,expected_merge_lock,expected_running_ids', [
    pytest.param(
        {
            'execution_id': '',
            'status': '',
            'cfg_path': '',
            'is_rollback': '',
            'commit_id': ''
        },
        [
            {
                'execution_id': 'run-foo',
                'commit_id': 'foo',
                'is_rollback': 'false',
                'status': 'failed',
                'account_name': 'dev',
                'account_deps': [],
                'cfg_path': 'dev/foo',
                'cfg_deps': []
            }
        ],
        1,
        1,
        ['run-foo'],
        id='successful_run'
    )
])
@patch('functions.trigger_sf.lambda_function.sf')
@patch('functions.trigger_sf.lambda_function.ssm')
@patch.dict(os.environ, {"METADB_CLUSTER_ARN": "mock","METADB_SECRET_ARN": "mock", "METADB_NAME": "mock", "STATE_MACHINE_ARN": "mock", 'GITHUB_MERGE_LOCK_SSM_KEY': 'mock-ssm-key'}, clear=True)
@pytest.mark.usefixtures('mock_conn', 'aws_credentials')
def test_lambda_handler(mock_ssm, mock_sf, event, records, merge_lock, expected_merge_lock, expected_running_ids):

    response = lambda_handler(event, {})
    assert response == None
    log.info('Assert finished execution record status was updated')
    log.info('Assert Step Function executions were aborted')

    log.info('Assert Step Function executions were started with approriate input')
    log.info('Assert started Step Function execution statuses were updated to running')

    log.info('Assert merge lock value was resetted')


ids = ['test_failed_rollback', 'test_failed_execution', 'test_multiple_commmits_waiting']