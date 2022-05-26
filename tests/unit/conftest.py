import pytest
import psycopg2
from psycopg2 import sql
import os
import timeout_decorator
import logging
import psycopg2.extras

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture(scope="session")
def conn():
    """psycopg2 connection with auto commit set to True"""
    conn = psycopg2.connect(connect_timeout=10)
    conn.set_session(autocommit=True)

    yield conn
    conn.close()


@pytest.fixture(scope="session")
def cur(conn):
    """psycopg2 cursor that returns dictionary type results {column_name: value}"""
    cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    yield cur
    cur.close()


@timeout_decorator.timeout(30)
@pytest.fixture(scope="session")
def setup_metadb(cur):
    """Creates `account_dim` and `executions` table"""
    log.info("Creating metadb tables")
    with open(
        f"{os.path.dirname(os.path.realpath(__file__))}/../../sql/create_metadb_tables.sql",
        "r",
    ) as f:
        cur.execute(
            sql.SQL(f.read().replace("$", "")).format(
                metadb_schema=sql.Identifier("public"),
                metadb_name=sql.Identifier(os.environ["PGDATABASE"]),
            )
        )


@pytest.fixture(scope="function")
def truncate_executions(cur):
    """Removes all rows from execution table after every test"""
    log.info("Setup: Truncating executions table")
    cur.execute("TRUNCATE executions")

    yield None

    log.info("Teardown: Truncating executions table")
    cur.execute("TRUNCATE executions")


@pytest.fixture()
def mock_conn(mocker, conn):
    """Patches AWS RDS client with psycopg2 client that connects to the local docker container Postgres database"""
    return mocker.patch("aurora_data_api.connect", return_value=conn, autospec=True)


@pytest.fixture(scope="function")
def aws_credentials():
    """
    Mocked AWS credentials needed to be set before importing Lambda Functions that define global boto3 clients.
    This prevents the region_name not specified errors.
    """
    os.environ["AWS_ACCESS_KEY_ID"] = "testing"
    os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
    os.environ["AWS_SECURITY_TOKEN"] = "testing"
    os.environ["AWS_SESSION_TOKEN"] = "testing"
    os.environ["AWS_DEFAULT_REGION"] = "us-west-2"
