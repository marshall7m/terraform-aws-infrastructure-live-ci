import pytest
import psycopg2
from psycopg2 import sql
import os
import timeout_decorator
import logging
import psycopg2.extras
import github

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
                metadb_schema=sql.Identifier("testing"),
                metadb_name=sql.Identifier(os.environ["PGDATABASE"]),
            )
        )
    yield None

    log.info("Dropping metadb tables")
    cur.execute("DROP TABLE IF EXISTS executions, account_dim")


@pytest.fixture(scope="function")
def truncate_executions(setup_metadb, cur):
    """Removes all rows from execution table after every test"""

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
    os.environ["AWS_ACCESS_KEY_ID"] = os.environ.get("AWS_ACCESS_KEY_ID", "testing")
    os.environ["AWS_SECRET_ACCESS_KEY"] = os.environ.get(
        "AWS_SECRET_ACCESS_KEY", "testing"
    )
    os.environ["AWS_SECURITY_TOKEN"] = os.environ.get("AWS_SECURITY_TOKEN", "testing")
    os.environ["AWS_SESSION_TOKEN"] = os.environ.get("AWS_SESSION_TOKEN", "testing")
    os.environ["AWS_REGION"] = os.environ.get("AWS_REGION", "us-west-2")
    os.environ["AWS_DEFAULT_REGION"] = os.environ.get("AWS_DEFAULT_REGION", "us-west-2")


@pytest.fixture(scope="session")
def gh():
    return github.Github(
        os.environ["TF_VAR_testing_unit_github_token"], retry=3
    ).get_user()


@pytest.fixture(scope="module")
def repo(gh, request):
    log.info(f"Creating testing repo: {request.param}")
    repo = gh.create_repo(request.param, auto_init=True)

    yield repo

    log.info(f"Deleting testing repo: {request.param}")
    repo.delete()
