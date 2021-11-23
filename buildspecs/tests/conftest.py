import pytest
import os
import psycopg2
import string
import random


pytest_plugins = ['buildspecs.tests.fixtures.mock_repo', 'buildspecs.tests.fixtures.mock_tables']
 
@pytest.fixture(scope="function", autouse=True)
def test_id():
    return ''.join(random.choice(string.ascii_lowercase) for _ in range(8))

@pytest.fixture(scope="session", autouse=True)
def conn():
    conn = psycopg2.connect()
    yield conn
    conn.close()

@pytest.fixture(scope="session", autouse=True)
def cur(conn):
    cur = conn.cursor()
    yield cur
    cur.close()

@pytest.fixture(scope="session", autouse=True)
def create_metadb_tables(conn, cur):
    yield cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/../../sql/create_metadb_tables.sql').read())

    cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/fixtures/clear_metadb_tables.sql').read())
    cur.execute("""
    DO $$
        DECLARE
            _tbl VARCHAR;
            clear_tables TEXT[] := ARRAY['executions', 'account_dim', 'commit_queue', 'pr_queue'];
            reset_tables TEXT[] := ARRAY['pr_queue', 'commit_queue'];
        BEGIN
            FOREACH _tbl IN ARRAY clear_tables LOOP
                PERFORM truncate_if_exists(%(schema)s, %(catalog)s, _tbl);
            END LOOP;

            FOREACH _tbl IN ARRAY reset_tables LOOP
                PERFORM truncate_if_exists(%(schema)s, %(catalog)s, _tbl);
            END LOOP;
        END
    $$ LANGUAGE plpgsql;
    """, {'schema': 'public', 'catalog': conn.info.dbname})