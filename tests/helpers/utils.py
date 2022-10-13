import uuid
import logging
import os
import json
import boto3
import aurora_data_api

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


null_provider_resource = """
provider "null" {}

resource "null_resource" "this" {}
"""


dummy_configured_provider_resource = """
terraform {
  required_providers {
    dummy = {
      source = "marshall7m/dummy"
      version = "0.0.3"
    }
  }
}

provider "dummy" {
  foo = "bar"
}

resource "dummy_resource" "this" {}
"""


def toggle_trigger(
    table: str, trigger: str, enable=False, rds_data_client=boto3.client("rds-data")
):
    """
    Toggles the tables associated testing trigger that creates random defaults to prevent any null violations

    Arguments:
        table: Table to insert the records into
        trigger: Trigger to enable/disable
        enable: Enables the table's associated trigger
    """
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        with open(
            f"{os.path.dirname(os.path.realpath(__file__))}/../helpers/testing_triggers.sql"
        ) as f:
            log.debug("Creating triggers for table")
            cur.execute(f.read())

            cur.execute(
                "ALTER TABLE {tbl} {action} TRIGGER {trigger}".format(
                    tbl=table,
                    action="ENABLE" if enable else "DISABLE",
                    trigger=trigger,
                )
            )


def insert_records(
    table, records, enable_defaults=None, rds_data_client=boto3.client("rds-data")
):
    """
    Toggles table's associated trigger and inserts list of dictionaries or a single dictionary into the table

    Arguments:
        table: Table to insert the records into
        records: List of dictionaries or a single dictionary containing record(s) to insert
        enable_defaults: Enables the table's associated trigger that inputs default values
    """
    if type(records) == dict:
        records = [records]

    cols = set().union(*(r.keys() for r in records))

    results = []
    try:
        if enable_defaults is not None:
            toggle_trigger(table, f"{table}_default", enable=enable_defaults)
        for record in records:
            cols = record.keys()
            log.info("Inserting record(s)")
            log.info(record)
            values = []
            for val in record.values():
                if type(val) == str:
                    values.append(f"'{val}'")
                elif type(val) == list:
                    values.append("'{" + ", ".join(val) + "}'")
                else:
                    values.append(str(val))
            query = """
            INSERT INTO {tbl} ({fields})
            VALUES({values})
            RETURNING *
            """.format(
                tbl=table,
                fields=", ".join(cols),
                values=", ".join(values),
            )

            log.debug(f"Running: {query}")
            with aurora_data_api.connect(
                database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
            ) as conn, conn.cursor() as cur:
                cur.execute(query)
                res = dict(zip([desc.name for desc in cur.description], cur.fetchone()))
            results.append(dict(res))
    except Exception as e:
        log.error(e)
        raise
    finally:
        if enable_defaults is not None:
            toggle_trigger(table, f"{table}_default", enable=False)
    return results


def check_ses_sender_email_auth(email_address: str, send_verify_email=False) -> bool:
    """
    Checks if AWS SES sender is authorized to send emails from it's address.
    If not authorized, the function can send a verification email.

    Arguments:
        email_address: Sender email address
        send_verify_email: Sends a verification email to the sender email address
            where the sender can authenticate their email address
    """
    ses = boto3.client("ses")
    verified = ses.list_verified_email_addresses()["VerifiedEmailAddresses"]
    if email_address in verified:
        return True
    else:
        if send_verify_email:
            log.info("Sending SES verification email")
            ses.verify_email_identity(EmailAddress=email_address)
        return False
