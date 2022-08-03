import logging
import json
import os
from pprint import pformat
import github
import boto3
import hmac
import hashlib
import re
import sys
from request_filter_groups import RequestFilter, ValidationError

sys.path.append(os.path.dirname(__file__) + "/..")
sys.path.append(os.path.dirname(__file__))
from invoker import Invoker  # noqa E402
from common.utils import (  # noqa E402
    ClientException,
    ServerException,
    aws_response,
    validate_sig,
    aws_encode,
)

ssm = boto3.client("ssm")

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def get_logs_url(context):
    return f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(context.log_group_name)}/log-events/{aws_encode(context.log_stream_name)}'


class InvokerHandler(object):
    def __init__(self, app, secret, token, commit_status_config={}):
        self.app = app
        self.secret = secret
        self.app_listeners = self.app.listeners
        self.gh = github.Github(token)
        self.app.gh = self.gh
        self.app.commit_status_config = commit_status_config

    def _get_header(self, key, request):
        """Return message header if exists or returns client exception"""

        try:
            return request["headers"][key]
        except KeyError:
            return aws_response(status_code=400, response="Missing header: " + key)

    def validate_file_paths(self, event_type, event, pattern):
        repo = self.gh.get_repo(event["body"]["repository"]["full_name"])
        if event_type == "pull_request":
            file_paths = [
                path.filename
                for path in repo.compare(
                    event["body"]["pull_request"]["base"]["sha"],
                    event["body"]["pull_request"]["head"]["sha"],
                ).files
            ]
        else:
            raise ServerException(f"Event type is not supported: {event_type}")
        log.debug(f"File paths:\n{file_paths}")

        valid = any([re.search(pattern, f) for f in file_paths])

        return valid

    def handle(self, event, context):
        try:
            RequestFilter.validate(
                event,
                [
                    {
                        "headers.x-github-event": ["required"]
                        + [f"regex:^{event}$" for event in self.app_listeners.keys()],
                        "headers.x-hub-signature-256": "required|regex:^sha256=.+$",
                        "body": "required",
                    }
                ],
            )
        except ValidationError as e:
            return aws_response(status_code=422, response=str(e))

        event_type = event["headers"]["x-github-event"]
        log.debug(f"GitHub event: {event_type}")

        log.info("Validating request signature")
        expected_sig = hmac.new(
            bytes(str(self.secret), "utf-8"),
            bytes(str(event["body"]), "utf-8"),
            hashlib.sha256,
        ).hexdigest()

        try:
            validate_sig(
                event["headers"]["x-hub-signature-256"].split("=", 1)[1], expected_sig
            )
        except ClientException as e:
            log.error(e, exc_info=True)
            return aws_response(status_code=402, response=str(e))

        event["body"] = json.loads(event["body"])
        hook_handlers = self.app_listeners[event_type]

        for handler in hook_handlers:

            log.debug(f"Function: {handler['function']}")

            log.info("Validating request content")
            try:
                RequestFilter.validate(event, handler["filter_groups"])
            except ValidationError as e:
                log.debug("Invalid request content")
                log.debug(f"Error:\n{e}")
                continue

            if os.environ.get("FILE_PATH_PATTERN"):
                log.info("Validating event file path changes")
                valid_file_path = self.validate_file_paths(
                    event_type, event, os.environ.get("FILE_PATH_PATTERN")
                )

                if not valid_file_path:
                    log.debug("PR does not contain valid file path changes")
                    continue
            else:
                log.info(
                    "$FILE_PATH_PATTERN is not found -- skipping file path validation"
                )

            log.info("Running handler")
            handler["function"](event, context)

        # TODO: create response for when no handlers were executed?
        return aws_response(
            status_code=200, response="Webhook event was successfully processed"
        )


app = Invoker()

common_filters = {
    "body.pull_request.base.ref": "regex:^" + os.environ.get("BASE_BRANCH", "") + "$",
}


def rule_not_true(x):
    """Workaround to Validator not having negative rules"""
    return x != True  # noqa : 712


@app.hook(
    event_type="pull_request",
    filter_groups=[
        {
            **{
                "body.pull_request.merged": rule_not_true,
                "body.action": lambda x: re.search("(opened|edited|reopened)", x)
                != None,  # noqa : 711
            },
            **common_filters,
        }
    ],
)
def open_pr(event, context):
    app.merge_lock(
        event["body"]["repository"]["full_name"],
        event["body"]["pull_request"]["head"]["ref"],
        get_logs_url(context),
    )
    app.trigger_pr_plan(
        event["body"]["repository"]["full_name"],
        event["body"]["pull_request"]["base"]["ref"],
        event["body"]["pull_request"]["head"]["ref"],
        event["body"]["pull_request"]["head"]["sha"],
        get_logs_url(context),
        app.commit_status_config.get("PrPlan"),
    )


@app.hook(
    event_type="pull_request",
    filter_groups=[
        {
            **{"body.pull_request.merged": "accepted", "body.action": "regex:^closed$"},
            **common_filters,
        }
    ],
)
def merged_pr(event, context):

    app.trigger_create_deploy_stack(
        event["body"]["repository"]["full_name"],
        event["body"]["pull_request"]["base"]["ref"],
        event["body"]["pull_request"]["head"]["ref"],
        event["body"]["pull_request"]["head"]["sha"],
        event["body"]["pull_request"]["number"],
        get_logs_url(context),
        app.commit_status_config.get("CreateDeployStack"),
    )


def lambda_handler(event, context):
    log.debug(f"Event:\n{pformat(event)}")

    token = ssm.get_parameter(
        Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    secret = ssm.get_parameter(
        Name=os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    commit_status_config = json.loads(
        ssm.get_parameter(Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"])["Parameter"][
            "Value"
        ]
    )

    invoker = InvokerHandler(
        app=app, secret=secret, token=token, commit_status_config=commit_status_config
    )
    invoker.handle(event, context)
