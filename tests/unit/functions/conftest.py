import pytest
import psycopg2
from psycopg2 import sql
import os
import timeout_decorator
import sys
import logging
import psycopg2.extras

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
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
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


def toggle_trigger(conn, table, trigger, enable=False):
    with conn.cursor() as cur:
        log.debug('Creating triggers for table')
        cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/../../helpers/testing_triggers.sql').read())

        cur.execute(sql.SQL("ALTER TABLE {tbl} {action} TRIGGER {trigger}").format(
            tbl=sql.Identifier(table),
            action=sql.SQL('ENABLE' if enable else 'DISABLE'),
            trigger=sql.Identifier(trigger)
        ))

        conn.commit()

@pytest.fixture(scope='function')
def insert_records(conn):
    def _insert(table, records, enable_defaults=None):
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            if type(records) == dict:
                records = [records]

            cols = set().union(*(r.keys() for r in records))

            results = []
            try:
                if enable_defaults != None:
                    toggle_trigger(conn, table, f'{table}_default', enable=enable_defaults)
                for record in records:
                    cols = record.keys()

                    log.info('Inserting record(s)')
                    log.info(record)
                    query = sql.SQL('INSERT INTO {tbl} ({fields}) VALUES({values}) RETURNING *').format(
                        tbl=sql.Identifier(table),
                        fields=sql.SQL(', ').join(map(sql.Identifier, cols)),
                        values=sql.SQL(', ').join(map(sql.Placeholder, cols))
                    )

                    log.debug(f'Running: {query.as_string(conn)}')
                    
                    cur.execute(query, record)
                    conn.commit()

                    record = cur.fetchone()
                    results.append(dict(record))
            except Exception as e:
                log.error(e)
                raise
            finally:
                if enable_defaults != None:
                    toggle_trigger(conn, table, f'{table}_default', enable=False)
        return results
    
    yield _insert
