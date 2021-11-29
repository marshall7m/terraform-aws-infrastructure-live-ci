import pytest
import os
import psycopg2
import string
import random
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


pytest_plugins = [
    'buildspecs.tests.fixtures.mock_repo',
    'buildspecs.tests.fixtures.mock_tables',
    'buildspecs.tests.fixtures.scenarios'
]
 
@pytest.fixture(scope="function", autouse=True)
def test_id():
    return ''.join(random.choice(string.ascii_lowercase) for _ in range(8))

@pytest.fixture(scope="session", autouse=True)
def conn():
    conn = psycopg2.connect()
    conn.set_session(autocommit=True)

    yield conn
    conn.close()

@pytest.fixture(scope="session", autouse=True)
def cur(conn):
    cur = conn.cursor()
    yield cur
    cur.close()

@pytest.fixture(scope="function", autouse=True)
def create_metadb_tables(cur):
    yield cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/../../sql/create_metadb_tables.sql').read())

    cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/../../helpers/cleanup_metadb_tables.sql').read())