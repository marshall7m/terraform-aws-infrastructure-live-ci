import pytest
import os
import psycopg2

from buildspecs.trigger_sf import TriggerSF
from buildspecs.postgres_helper import PostgresHelper

pytest_plugins = ['buildspecs.tests.fixtures.mocks']

@pytest.fixture(scope="session", autouse=True)
def conn():
    yield psycopg2.connect()
    conn.close()

@pytest.fixture(scope="session", autouse=True)
def cur(conn):
    yield conn.cursor()
    cur.close()

@pytest.fixture(scope="function", autouse=True)
def instance():
    trigger = TriggerSF()

@pytest.fixture(scope="function", autouse=True)
def codebuild_env():
    os.environ['CODEBUILD_INITIATOR'] = 'rule/test'
    os.environ['EVENTBRIDGE_FINISHED_RULE'] = 'rule/test'
    os.environ['BASE_REF'] = 'master'

def create_metadb_tables(cur):
    yield cur.execute(open('../../sql/create_metadb_tables.sql').read())
    
    cur.execute(open('./fixtures/clear_metadb_tables.sql').read())
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

