import uuid
import logging
from psycopg2 import sql
import psycopg2
import os
import subprocess
import shlex

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def dummy_tf_output():
    return f"""
    output "_{uuid.uuid4()}" {{
        value = "_{uuid.uuid4()}"
    }}
    """

def dummy_tf_provider_resource():
    return """
    provider "null" {}

    resource "null_resource" "this" {}
    """


def dummy_tf_github_repo(repo_name=f'dummy-repo-{uuid.uuid4()}'):
    return f"""
    terraform {{
    required_providers {{
        github = {{
        source  = "integrations/github"
        version = "4.9.3"
        }}
    }}
    }}
    provider "aws" {{}}

    data "aws_ssm_parameter" "github_token" {{
        name = "admin-github-token"
    }}

    provider "github" {{
        owner = "marshall7m"
        token = data.aws_ssm_parameter.github_token.value
    }}

    resource "github_repository" "dummy" {{
    name        = "{repo_name}"
    visibility  = "public"
    }}
    """

def toggle_trigger(conn, table, trigger, enable=False):
    '''Toggles the tables associated testing trigger that creates random defaults to prevent any null violations'''
    with conn.cursor() as cur:
        log.debug('Creating triggers for table')
        cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/../helpers/testing_triggers.sql').read())

        cur.execute(sql.SQL("ALTER TABLE {tbl} {action} TRIGGER {trigger}").format(
            tbl=sql.Identifier(table),
            action=sql.SQL('ENABLE' if enable else 'DISABLE'),
            trigger=sql.Identifier(trigger)
        ))

        conn.commit()

def insert_records(conn, table, records, enable_defaults=None):
    '''Toggles table's associated trigger and inserts list of dictionaries or a single dictionary into the table'''
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

def tf_version(version='min-required'):
    version = subprocess.run(shlex.split('terraform --version'), capture_output=True, text=True)
    if version.returncode == 0:
        log.info('Terraform found in $PATH -- skip installing Terraform with tfenv')
        log.info(f'Terraform Version: {version.stdout}')
    else:
        log.info('Terraform not found in $PATH -- installing Terraform with tfenv')
        out = subprocess.run(shlex.split(f'tfenv install {version} && tfenv use {version}'), capture_output=True, check=True, text=True
        )
        log.debug(f'tfenv out: {out.stdout}')