import aurora_data_api
import os
import boto3
import logging
import json
from pprint import pformat
from functools import wraps
import sys
from request_filter_groups import RequestFilter, ValidationError

sys.path.append(os.path.dirname(__file__) + "/..")
from common_lambda.utils import (
    ClientException,
    get_email_approval_sig,
    aws_response,
    validate_sig,
    aws_decode,
)

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class App(object):
    def __init__(self):
        self.listeners = {}

    def update_vote(self, execution_arn: str, action: str, voter: str, task_token: str):
        sf = boto3.client("stepfunctions")
        execution = sf.describe_execution(executionArn=execution_arn)
        status = execution["status"]
        execution_id = execution["name"]

        if status == "RUNNING":
            log.info("Updating vote count")
            # NOTE: If query execution time is too long and
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

            log.debug(f"Record:\n{pformat(record)}")
            if (
                len(record["approval_voters"]) == record["min_approval_count"]
                or len(record["rejection_voters"]) == record["min_rejection_count"]
            ):
                log.info("Voter count meets requirement")
                log.info("Sending task token to Step Function Machine")
                sf.send_task_success(
                    taskToken=task_token,
                    output=json.dumps(action),
                )
                return aws_response(
                    status_code=200, response="Your choice has been submitted"
                )
        else:
            raise ClientException(
                f"Approval submissions are not available anymore -- Execution Status: {status}"
            )

    def validate_ses_request(self, func):
        @wraps(func)
        def decorater(event):
            try:
                RequestFilter.validate(
                    event,
                    [
                        {
                            "queryStringParameters.ex": "required|string",
                            "queryStringParameters.recipient": "required|string",
                            "queryStringParameters.action": "required|string",
                            "queryStringParameters.exArn": "required|string",
                            "queryStringParameters.taskToken": "required|string",
                            "queryStringParameters.X-SES-Signature-256": "required|string",
                            "requestContext.http": "required",
                        }
                    ],
                )
            except ValidationError as e:
                return aws_response(status_code=422, response=str(e))

            ssm = boto3.client("ssm")

            secret = ssm.get_parameter(
                Name=os.environ["EMAIL_APPROVAL_SECRET_SSM_KEY"], WithDecryption=True
            )["Parameter"]["Value"]

            event["queryStringParameters"] = {
                k: aws_decode(v) for k, v in event["queryStringParameters"].items()
            }

            actual_sig = event.get("queryStringParameters", {}).get(
                "X-SES-Signature-256", ""
            )
            expected_sig = get_email_approval_sig(
                secret,
                event.get("queryStringParameters", {}).get("ex", ""),
                aws_decode(event.get("queryStringParameters", {}).get("recipient", "")),
                event.get("queryStringParameters", {}).get("action", ""),
            )

            try:
                validate_sig(actual_sig, expected_sig)
            except ClientException as e:
                return aws_response(status_code=401, response=str(e))

            return func(event)

        return decorater

    def vote(self, method, path):
        def __call__(func, *args, **kwargs):
            """Collects view functions by resource path and method"""
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
