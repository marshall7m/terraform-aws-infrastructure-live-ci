import pytest
import os
import psycopg2

from buildspecs.trigger_sf import TriggerSF
from buildspecs.postgres_helper import PostgresHelper

pytest_plugins = ['buildspecs.tests.mocks']

@pytest.fixture(scope="session", autouse=True)
def conn():
    return psycopg2.connect()

@pytest.fixture(scope="session", autouse=True)
def cur(conn):
    return conn.cursor()

@pytest.fixture(scope="function", autouse=True)
def instance():
    trigger = TriggerSF()

@pytest.fixture(scope="session", autouse=True)
def setup_file(cur):
    os.environ['CODEBUILD_INITIATOR'] = 'rule/test'
    os.environ['EVENTBRIDGE_FINISHED_RULE'] = 'rule/test'
    os.environ['BASE_REF'] = 'master'

    cur.execute(open('../../sql/create_metadb_tables.sql').read())