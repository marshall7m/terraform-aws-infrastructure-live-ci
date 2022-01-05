import pytest
import psycopg2

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
