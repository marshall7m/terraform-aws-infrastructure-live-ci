import pytest
import psycopg2
from psycopg2 import sql
from unittest.mock import patch
import os
import logging
import sys
from functions.trigger_sf.lambda_function import lambda_handler
import shutil
import uuid
import json
import aurora_data_api
from pprint import pformat
from psycopg2.extras import execute_values
import timeout_decorator
import sys
log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@timeout_decorator.timeout(30)
@pytest.fixture(scope='session', autouse=True)
def setup_metadb(cur):
    log.info('Creating metadb tables')
    with open(f'{os.path.dirname(os.path.realpath(__file__))}/../../../sql/create_metadb_tables.sql', 'r') as f:
        cur.execute(sql.SQL(f.read().replace('$', '')).format(metadb_schema=sql.Identifier('dev'), metadb_name=sql.Identifier(os.environ['PGDATABASE'])))
    return None

@patch('aurora_data_api.connect', return_value=psycopg2.connect())
@patch.dict(os.environ, {"METADB_CLUSTER_ARN": "mock", "METADB_SECRET_ARN": "mock", "METADB_NAME": "mock", "STATE_MACHINE_ARN": "mock"}, clear=True)
@patch('boto3.client', return_value=None)
def run(mock_conn, mock_aws_client):
    log.info('Running Lambda Function')
    return lambda_handler({}, {})

@timeout_decorator.timeout(30)
@pytest.fixture(scope='function')
def records(request, cur, conn):
    log.info('Inserting records')

    cols = set().union(*(s.keys() for s in request.param))
    col_tpl = '(' + ', '.join([f'%({col})s' for col in cols]) + ')'
    log.debug(f'Stack column template: {col_tpl}')
    query = sql.SQL("INSERT INTO executions ({cols}) VALUES %s").format(cols=sql.SQL(', ').join(map(sql.Identifier, cols)))
    log.debug(f'Query:\n{query.as_string(conn)}')

    results = execute_values(cur, query, request.param, template=col_tpl)

    yield results
    
    # log.info('Truncating executions table')
    # cur.execute("TRUNCATE executions")

@pytest.mark.parametrize('records', [
    (
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
        ]
    )
], indirect=True)
@timeout_decorator.timeout(15)
def test_select_target_ids(records):

    print(records)

@pytest.mark.skip(reason='Not implemented')
def test_multiple_commmits_waiting():
    pass

def execution_output(request):
    os.environ['EXECUTION_OUTPUT'] = json.dumps(request.param)
    yield os.environ['EXECUTION_OUTPUT']
    del os.environ['EXECUTION_OUTPUT']

@pytest.mark.skip(reason='Not implemented')
@pytest.mark.parametrize('execution_output', [
    {
        'execution_id': '',
        'status': '',
        'cfg_path': '',
        'is_rollback': '',
        'commit_id': ''
    }
])
def test_failed_execution(execution_output):
    pass

@pytest.mark.skip(reason='Not implemented')
def test_failed_rollback():
    pass