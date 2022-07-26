import aurora_data_api
import hmac
import os
import boto3
import logging
import json
from pprint import pformat
from functools import wraps
from common.utils import (
    ClientException,
    ServerException,
    get_email_approval_sig,
    aws_response,
)

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class App(object):
    def __init__(self):
        self.sf = boto3.client("stepfunctions")

        self.listeners = {}

    def validate_sig(self, actual_sig: str, expected_sig: str):
        """
        Authenticates request by comparing the request's SHA256
        signature value to the expected SHA-256 value
        """

        log.info("Authenticating approval request")
        log.debug(f"Actual: {actual_sig}")
        log.debug(f"Expected: {expected_sig}")

        authorized = hmac.compare_digest(str(actual_sig), str(expected_sig))

        if not authorized:
            raise ClientException(
                "Header signature and expected signature do not match"
            )

    def voter_count_met(self, task_token, action):
        log.info("Sending task token to Step Function Machine")
        self.sf.send_task_success(
            taskToken=task_token,
            output=json.dumps(action),  # noqa: E501
        )

        # TODO: add logic to send notifactions to users who subscribe to approval count met event

    def update_vote(self, execution_id: str, action: str, voter: str, task_token: str):
        status = self.sf.describe_execution(executionArn=execution_id)["status"]
        if status == "RUNNING":
            log.info("Updating vote count")
            # TODO: If query execution time is too long and
            #  causes downstream timeouts, invoke async lambda with
            #  query and return submission response from this function
            with aurora_data_api.connect(
                aurora_cluster_arn=os.environ["METADB_CLUSTER_ARN"],
                secret_arn=os.environ["METADB_SECRET_ARN"],
                database=os.environ["METADB_NAME"],
            ) as conn:
                with conn.cursor() as cur:
                    with open(
                        f"{os.path.dirname(os.path.realpath(__file__))}/update_vote.sql",  # noqa: E501
                        "r",
                    ) as f:
                        cur.execute(
                            f.read().format(
                                action=action,
                                recipient=voter,
                                execution_id=execution_id,
                            )
                        )
                        results = cur.fetchone()
                        if results is None:
                            raise ClientException(
                                f"Record with execution ID: {execution_id} does not exist"
                            )
                        try:
                            record = dict(
                                zip(
                                    [
                                        "status",
                                        "approval_voters",
                                        "min_approval_count",
                                        "rejection_voters",
                                        "min_rejection_count",
                                    ],
                                    list(results),
                                )
                            )
                        except TypeError as e:
                            if results is None:
                                raise ClientException(
                                    f"Record with execution ID: {execution_id} does not exist"
                                )
                            else:
                                raise e

            log.debug(f"Record:\n{pformat(record)}")
            if (
                len(record["approval_voters"]) == record["min_approval_count"]
                or len(record["rejection_voters"]) == record["min_rejection_count"]
            ):
                log.info("Voter count meets requirement")
                self.voter_count_met(task_token, action)
        else:
            raise ClientException(
                f"Approval submissions are not available anymore -- Execution Status: {status}"
            )

    def validate_ses_request(self, func):
        @wraps(func)
        def decorater(event):
            try:
                actual_sig = event.get("X-SES-Signature-256")
                expected_sig = get_email_approval_sig(
                    event.get("domainName", ""),
                    event.get("requestContext", {}).get("http", {}).get("method", ""),
                    event.get("body", {}).get("recipient", ""),
                )
            except ServerException as e:
                return aws_response(response=e)

            try:
                self.validate_sig(actual_sig, expected_sig)
            except ClientException as e:
                return aws_response(status_code=401, response=str(e))
            return func(event)

        return decorater

    def vote(self, method, path):
        def __call__(func, *args, **kwargs):
            self.listeners[path] = {method.upper(): func}

        return __call__


class ApprovalHandler(object):
    def __init__(self, app):
        self.app = app
        self.app_listeners = self.app.listeners

    def handle(self, event, context):
        method = event.get("requestContext", {}).get("http", {}).get("method")
        if method is None:
            method = event.get("requestContext", {}).get("httpMethod")

        path = event.get("requestContext", {}).get("http", {}).get("path")
        if path is None:
            path = event.get("rawPath")

        log.debug(f"Method: {method}")
        log.debug(f"Path: {path}")
        log.debug(f"Listeners: {self.app_listeners}")
        try:
            func = self.app_listeners[path][method]
        except KeyError:
            return aws_response(status_code=404, response="Not Found")

        return func(event)
