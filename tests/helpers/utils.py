import uuid
import logging
import os
import json
import time
from typing import Union
from pprint import pformat
import subprocess
import shlex
import requests
from requests.models import Response
import imaplib
import email

import boto3
import aurora_data_api
import github
import timeout_decorator
from mechanize._form import parse_forms
from mechanize._html import content_parser

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

rds_data_client = boto3.client(
    "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
)


def terra_version(binary: str, version: str, overwrite=False):

    """
    Installs Terraform via tfenv or Terragrunt via tgswitch.
    If version='min-required' for Terraform installations, tfenv will scan
    the cwd for the minimum version required within Terraform blocks
    Arguments:
        binary: Binary to manage version for
        version: Semantic version to install and/or use
        overwrite: If true, version manager will install and/or switch to the
        specified version even if the binary is found in $PATH.
    """

    if not overwrite:
        check_version = subprocess.run(
            shlex.split(f"{binary} --version"), capture_output=True, text=True
        )
        if check_version.returncode == 0:
            log.info(f"{binary} version: {check_version.stdout} " "found in $PATH")
            return
        else:
            log.info(f"{binary} version: {check_version.stdout} not found in $PATH")
    if binary == "terragrunt" and version == "latest":
        version = requests.get(
            "https://warrensbox.github.io/terragunt-versions-list/"
        ).json()["Versions"][0]

    cmds = {
        "terraform": f"tfenv install {version} && tfenv use {version}",
        "terragrunt": f"tgswitch {version}",
    }
    log.debug(f"Running command: {cmds[binary]}")
    try:
        subprocess.run(
            cmds[binary],
            shell=True,
            capture_output=True,
            check=True,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        log.error(e, exc_info=True)
        raise e


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


def toggle_trigger(table: str, trigger: str, enable=False):
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
    table,
    records,
    enable_defaults=None,
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


def commit(repo, branch, changes, commit_message):
    """Creates a local commit"""
    elements = []
    for filepath, content in changes.items():
        log.debug(f"Creating file: {filepath}")
        blob = repo.create_git_blob(content, "utf-8")
        elements.append(
            github.InputGitTreeElement(
                path=filepath, mode="100644", type="blob", sha=blob.sha
            )
        )

    head_sha = repo.get_branch(branch).commit.sha
    base_tree = repo.get_git_tree(sha=head_sha)
    tree = repo.create_git_tree(elements, base_tree)
    parent = repo.get_git_commit(sha=head_sha)
    commit = repo.create_git_commit(commit_message, tree, [parent])

    return commit


def push(repo, branch: str, changes=dict[str, str], commit_message="Adding test files"):
    """Pushes changes to associated repo and returns the commit ID"""
    try:
        ref = repo.get_git_ref(f"heads/{branch}")
    except Exception:
        log.debug(f"Creating ref for branch: {branch}")
        ref = repo.create_git_ref(
            ref="refs/heads/" + branch,
            sha=repo.get_branch(repo.default_branch).commit.sha,
        )
        log.debug(f"Ref: {ref.ref}")

    commit_obj = commit(repo, branch, changes, commit_message)
    log.debug(f"Pushing commit ID: {commit_obj.sha}")
    ref.edit(sha=commit_obj.sha)

    return commit_obj.sha


def wait_for_finished_task(
    cluster: str, task_arn: str, endpoint_url=None, sleep=5
) -> str:
    """Waits for ECS task to return a STOPPED status"""
    ecs = boto3.client("ecs", endpoint_url=endpoint_url)
    task_status = None

    while task_status != "STOPPED":
        time.sleep(sleep)
        try:
            task_status = ecs.describe_tasks(cluster=cluster, tasks=[task_arn],)[
                "tasks"
            ][0]["lastStatus"]
            log.debug(f"Task Status: {task_status}")

        except IndexError:
            log.debug("Task does not exist yet")

    return task_status


def get_finished_commit_status(
    context, repo, commit_id, wait=3, token=None, max_attempts=30
):
    attempts = 0
    state = None
    while state in [None, "pending"]:
        if attempts == max_attempts:
            raise TimeoutError(
                "Max Attempts reached -- Finished commit status is not found"
            )
        log.debug(f"Waiting {wait} seconds")
        time.sleep(wait)
        status = get_commit_status(repo.full_name, commit_id, context, token)
        state = getattr(status, "state", None)
        log.debug(f"Status state: {state}")

        attempts += 1

    return status


def get_commit_status(
    repo_full_name: str, commit_id: str, context: str, token: str = None
) -> str:
    """Returns commit status associated with the passed context argument"""
    if not token:
        token = os.environ["GITHUB_TOKEN"]

    gh = github.Github(login_or_token=token)
    repo = gh.get_repo(repo_full_name)
    for status in repo.get_commit(commit_id).get_statuses():
        if status.context == context:
            return status


def get_sf_status_event(arn, state, wait=10):
    exited_event = None
    log.debug(f"Waiting on state to finish: {state}")
    while not exited_event:
        time.sleep(wait)
        exited_event = get_sf_state_event(arn, state, "stateExitedEventDetails")
    status_event = [e for e in exited_event if e["id"] == exited_event["id"] - 1][0]
    "taskFailedEventDetails"
    return status_event


# TODO: remove and replace with get_sf_status_event() in integration tests
def assert_sf_state_type(
    execution_arn: str, state_name: str, expected_status: str
) -> None:
    """
    Waits for the Step Function's associated task to finish and assert
    that the task status matches the expected status

    Arguments:
        execution_arn: ARN of the Step Function execution
        state_name: State name within the Step Function definition
        expected_status: Expected task status
    """
    log.info(f"Waiting for Step Function task to finish: {state_name}")
    exited_event = None
    while not exited_event:
        time.sleep(10)
        exited_event = get_sf_state_event(
            execution_arn, state_name, "stateExitedEventDetails"
        )
    status_event = [e for e in exited_event if e["id"] == exited_event["id"] - 1][0]

    log.info(f"Assert state: {state_name} has the expected status: {expected_status}")
    try:
        assert status_event["type"] == expected_status
    except AssertionError as e:
        log.debug(f"{state_name} status event:\n{pformat(status_event)}")

        cause = json.loads(status_event["taskFailedEventDetails"]["cause"])
        log.error(f"Cause:\n{cause}")

        raise e


@timeout_decorator.timeout(30)
def get_sf_state_event(execution_arn: str, state: str, event_type: str) -> dict:
    """
    Returns the Step Funciton execution event associated with the passed state name

    Arguments:
        execution_arn: Step Funciton execution ARN
        state: State name within the Step Function definition
        event_type: Step Function execution event type (e.g. taskScheduledEventDetails, stateExitedEventDetails)
    """
    sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))

    events = sf.get_execution_history(
        executionArn=execution_arn, includeExecutionData=True
    )["events"]

    for event in events:
        if event.get(event_type, {}).get("name", None) == state:
            return event


def get_sf_approval_state_msg(arn: str) -> dict:
    """Returns Step Function execution's SNS approval message parameters"""
    sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))
    events = sf.get_execution_history(executionArn=arn, includeExecutionData=True)[
        "events"
    ]

    for event in events:
        if (
            event.get("taskScheduledEventDetails", {}).get("resource")
            == "publish.waitForTaskToken"
        ):
            return json.loads(event["taskScheduledEventDetails"]["parameters"])[
                "Message"
            ]


def ses_approval(
    username: str,
    password: str,
    msg_from: str,
    msg_subject: str,
    action: str,
    host=None,
    mailboxes=["INBOX"],
    wait=5,
    max_attempts=3,
) -> Response:
    """
    Finds the approval email within email inbox, extracts approval action
    form from email and clicks on the requested approval action button

    Arguments:
        username: Email username/address
        password: Email password/token
        msg_from: Sender email address to filter the incoming emails from
        msg_subject: Email subject to filter the incoming emails from
        action: Approval action to choose within form
        host: Email's associated host
        mailboxes: Mailboxes to check within
        wait: Seconds to wait before refreshing inbox
        max_attempts: Maximum number of attempts to retreive approval email
    """
    url = "http://placeholder.com"
    if not host:
        if username.split("@")[-1] == "gmail.com":
            host = "imap.gmail.com"
        else:
            raise Exception("Could not identify host")

    with imaplib.IMAP4_SSL(host=host, port=imaplib.IMAP4_SSL_PORT) as imap_ssl:
        log.debug("Logging into mailbox")
        imap_ssl.login(username, password)

        attempt = 0
        mail_ids = []
        while len(mail_ids) == 0:
            if attempt == max_attempts:
                raise TimeoutError("Timeout reached -- Message is not found")

            time.sleep(wait)
            imap_ssl.noop()

            for box in mailboxes:
                imap_ssl.select(mailbox=box, readonly=True)
                # filters messages by sender, subject and recipient
                _, mails = imap_ssl.search(
                    None, f'(FROM "{msg_from}" Subject "{msg_subject}" To "{username}")'
                )
                mail_ids = [int(i) for i in mails[0].decode().split()]
                log.debug(f"Total Mail IDs : {len(mail_ids)}")

                if len(mail_ids) > 0:
                    # gets largest email ID which is the most recent
                    log.debug(f"Found message in mailbox: {box}")
                    mail_id = max(mail_ids)
                    break

            attempt += 1

        log.debug(f"Mail ID: {mail_id}")
        _, mail_data = imap_ssl.fetch(str(mail_id), "(RFC822)")
        message = email.message_from_bytes(mail_data[0][1])
        for part in message.walk():
            # parses only html data
            if part.get_content_type() == "text/html":
                html = f"{part.get_payload(decode=True)}".replace("b'", "")
                # parses form data from html
                root = content_parser(html, url)
                form, _ = parse_forms(root, url)
                for f in form:
                    # finds submit button within form
                    if f.find_control(type="submit").value == action:
                        # gets request instance associated with clicking on the button
                        req = f.click()
                        return requests.post(req.full_url)

                log.debug(
                    f"Action was not found in any HTML form -- check if action is valid: {action}"
                )


def get_execution_arn(arn: str, name: str) -> Union[str, None]:
    """
    Gets the Step Function execution ARN associated with the passed execution name

    Arguments:
        arn: ARN of the Step Function state machine
        execution_id: Name of the Step Function execution
    """
    sf = boto3.client("stepfunctions")
    for execution in sf.list_executions(stateMachineArn=arn)["executions"]:
        if execution["name"] == name:
            return execution["executionArn"]


def get_finished_sf_execution(arn: str, wait=5, max_attempts=3):
    """Waits till Step Function execution is finished and returns describe execution response"""
    sf = boto3.client("stepfunctions")
    status = None
    attempts = 0
    while status not in ["SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"]:
        if attempts == max_attempts:
            raise TimeoutError("Max attempts reached -- Execution is still running")

        response = sf.describe_execution(executionArn=arn)
        status = response["status"]
        log.debug(f"Execution status: {status}")

        attempts += 1
        time.sleep(wait)

    return response
