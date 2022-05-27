import uuid
import logging
from psycopg2 import sql
import psycopg2
import os
import json

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def tf_vars_to_json(tf_vars: dict) -> dict:
    for k, v in tf_vars.items():
        if type(v) not in [str, bool, int, float]:
            tf_vars[k] = json.dumps(v)

    return tf_vars


def dummy_tf_output(name=None, value=None):
    if not name:
        name = f"_{uuid.uuid4()}"

    if not value:
        value = f"_{uuid.uuid4()}"

    return f"""
    output "{name}" {{
        value = "{value}"
    }}
    """


def dummy_tf_provider_resource():
    return """
    provider "null" {}

    resource "null_resource" "this" {}
    """


def dummy_tf_github_repo(repo_name=None):
    if not repo_name:
        repo_name = f"dummy-repo-{uuid.uuid4()}"

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
    """Toggles the tables associated testing trigger that creates random defaults to prevent any null violations"""
    with conn.cursor() as cur:
        log.debug("Creating triggers for table")
        cur.execute(
            open(
                f"{os.path.dirname(os.path.realpath(__file__))}/../helpers/testing_triggers.sql"
            ).read()
        )

        cur.execute(
            sql.SQL("ALTER TABLE {tbl} {action} TRIGGER {trigger}").format(
                tbl=sql.Identifier(table),
                action=sql.SQL("ENABLE" if enable else "DISABLE"),
                trigger=sql.Identifier(trigger),
            )
        )

        conn.commit()


def insert_records(conn, table, records, enable_defaults=None):
    """Toggles table's associated trigger and inserts list of dictionaries or a single dictionary into the table"""
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        if type(records) == dict:
            records = [records]

        cols = set().union(*(r.keys() for r in records))

        results = []
        try:
            if enable_defaults is not None:
                toggle_trigger(conn, table, f"{table}_default", enable=enable_defaults)
            for record in records:
                cols = record.keys()

                log.info("Inserting record(s)")
                log.info(record)
                query = sql.SQL(
                    "INSERT INTO {tbl} ({fields}) VALUES({values}) RETURNING *"
                ).format(
                    tbl=sql.Identifier(table),
                    fields=sql.SQL(", ").join(map(sql.Identifier, cols)),
                    values=sql.SQL(", ").join(map(sql.Placeholder, cols)),
                )

                log.debug(f"Running: {query.as_string(conn)}")

                cur.execute(query, record)
                conn.commit()

                results.append(dict(cur.fetchone()))
        except Exception as e:
            log.error(e)
            raise
        finally:
            if enable_defaults is not None:
                toggle_trigger(conn, table, f"{table}_default", enable=False)
    return results
