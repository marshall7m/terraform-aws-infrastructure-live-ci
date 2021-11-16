import psycopg2
import logging
import os

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class PostgresHelper:
    def __init__(self):
        self.conn = psycopg2.connect()
        self.cur = self.conn.cursor()
    def close_conn(self):
        if self.conn:
            log.info('Closing PostgreSQL connection')
            self.conn.close()
        else:
            log.info('No PostgreSQL connection is identified')