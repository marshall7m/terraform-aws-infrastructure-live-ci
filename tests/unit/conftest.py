import logging
import os

import pytest
import timeout_decorator
import aurora_data_api

from tests.helpers.utils import rds_data_client

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@timeout_decorator.timeout(30)
@pytest.fixture(scope="session")
def setup_metadb():
    """Creates `account_dim` and `executions` table"""
    log.info("Creating metadb tables")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        with open(
            f"{os.path.dirname(os.path.realpath(__file__))}/../../sql/create_metadb_tables.sql",
            "r",
        ) as f:
            cur.execute(
                f.read()
                .replace("$", "")
                .format(
                    metadb_schema="testing",
                    metadb_name=os.environ["PGDATABASE"],
                )
            )
    yield None

    log.info("Dropping metadb tables")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS executions, account_dim")


@pytest.fixture(scope="function")
def truncate_executions(setup_metadb):
    """Removes all rows from execution table after every test"""

    yield None

    log.info("Teardown: Truncating executions table")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute("TRUNCATE executions")
