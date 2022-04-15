import pytest
import psycopg2
from psycopg2 import sql
import os
import timeout_decorator
import sys
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="session", autouse=True)
def conn():
    conn = psycopg2.connect(connect_timeout=10)
    conn.set_session(autocommit=True)

    yield conn
    conn.close()

@pytest.fixture(scope='session', autouse=True)
def cur(conn):
    # cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur = conn.cursor()
    yield cur
    cur.close()

@timeout_decorator.timeout(30)
@pytest.fixture(scope='session', autouse=True)
def setup_metadb(cur):
    log.info('Creating metadb tables')
    with open(f'{os.path.dirname(os.path.realpath(__file__))}/../../../sql/create_metadb_tables.sql', 'r') as f:
        cur.execute(sql.SQL(f.read().replace('$', '')).format(metadb_schema=sql.Identifier('public'), metadb_name=sql.Identifier(os.environ['PGDATABASE'])))

@pytest.fixture(scope='function', autouse=True)
def truncate_executions(cur):
    log.info('Truncating executions table')
    cur.execute("TRUNCATE executions")

@pytest.fixture(autouse=True)
def mock_conn(mocker, conn):
    mocker.patch('aurora_data_api.connect', return_value=conn)

@pytest.fixture(scope='function')
def aws_credentials():
    '''Mocked AWS Credentials'''
    os.environ['AWS_ACCESS_KEY_ID'] = 'testing'
    os.environ['AWS_SECRET_ACCESS_KEY'] = 'testing'
    os.environ['AWS_SECURITY_TOKEN'] = 'testing'
    os.environ['AWS_SESSION_TOKEN'] = 'testing'
    os.environ['AWS_DEFAULT_REGION'] = 'us-west-2'