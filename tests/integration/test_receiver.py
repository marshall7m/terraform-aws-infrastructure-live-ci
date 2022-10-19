import os
import logging
import json
import random
import hmac
import hashlib

import pytest
from unittest.mock import patch
from moto import mock_ssm, mock_ecs
import boto3

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

base_event = {
    "body": {
        "repository": {"full_name": "test-repo"},
        "pull_request": {
            "number": 1,
            "base": {"sha": "base-sha", "ref": "master"},
            "head": {"sha": "head-sha", "ref": "head"},
        },
    },
    "headers": {
        "content-type": "application/json",
        "x-github-event": "pull_request",
        "x-hub-signature-256": "sha256=12321",
    },
    "isBase64Encoded": False,
    "queryStringParameters": {"parameter1": "value1,value2", "parameter2": "value"},
    "rawPath": "/my/path",
    "rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value",
    "requestContext": {
        "accountId": "123456789012",
        "apiId": "<urlid>",
        "domainName": "<url-id>.lambda-url.us-west-2.on.aws",
        "domainPrefix": "<url-id>",
        "http": {
            "method": "POST",
            "path": "/my/path",
            "protocol": "HTTP/1.1",
            "sourceIp": "123.123.123.123",
            "userAgent": "agent",
        },
        "requestId": "id",
        "routeKey": "$default",
        "stage": "$default",
        "time": "12/Mar/2020:19:03:58 +0000",
        "timeEpoch": 1583348638390,
    },
    "routeKey": "$default",
    "version": "2.0",
}


class MockCompareFile:
    def __init__(self, filename, status="added"):
        self.filename = filename
        self.status = status


compare_files = [MockCompareFile("foo/a.tf"), MockCompareFile("bar/b.tf")]


def assert_commit_status_state(mock_gh, expected_state):
    commit_states = [
        call.kwargs["state"]
        for call in mock_gh.get_repo.return_value.get_branch.return_value.commit.create_status.call_args_list
    ]
    for state in commit_states:
        assert state == expected_state


class MockContext(object):
    def __init__(self):
        self.function_name = "test-function"
        self.function_version = "test-version"
        self.invoked_function_arn = (
            "arn:aws:lambda:us-east-1:123456789012:function:{name}:{version}".format(
                name=self.function_name, version=self.function_version
            )
        )
        self.memory_limit_in_mb = float("inf")
        self.log_group_name = "test-group"
        self.log_stream_name = "test-stream"
        self.client_context = None

        self.aws_request_id = "-".join(
            [
                "".join([random.choice("0123456789abcdef") for _ in range(0, n)])
                for n in [8, 4, 4, 4, 12]
            ]
        )


context = MockContext()
mock_gh_wh_secret = "mock-secret"


@pytest.fixture()
def merge_event():
    event = base_event.copy()

    event["body"]["pull_request"]["merged"] = True
    event["body"]["action"] = "closed"

    valid_sig = hmac.new(
        bytes(str(mock_gh_wh_secret), "utf-8"),
        bytes(json.dumps(event.get("body")), "utf-8"),
        hashlib.sha256,
    ).hexdigest()

    event["headers"]["x-hub-signature-256"] = "sha256=" + valid_sig

    event["body"] = json.dumps(event["body"])
    return event


@pytest.fixture()
def open_pr_event():
    event = base_event.copy()

    event["body"]["pull_request"]["merged"] = False
    event["body"]["action"] = "opened"

    valid_sig = hmac.new(
        bytes(str(mock_gh_wh_secret), "utf-8"),
        bytes(json.dumps(event.get("body")), "utf-8"),
        hashlib.sha256,
    ).hexdigest()
    event["headers"]["x-hub-signature-256"] = "sha256=" + valid_sig

    event["body"] = json.dumps(event["body"])
    return event


@pytest.fixture
def ssm_params():
    with mock_ssm() as ssm_context:
        os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"] = "mock-secret-key"
        os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"] = "mock-commit-status-key"
        os.environ["GITHUB_TOKEN_SSM_KEY"] = "mock-token-key"
        os.environ["MERGE_LOCK_SSM_KEY"] = "mock-merge-lock-key"

        ssm = boto3.client("ssm")

        ssm.put_parameter(
            Name=os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"], Value=mock_gh_wh_secret
        )

        ssm.put_parameter(Name=os.environ["MERGE_LOCK_SSM_KEY"], Value="true")

        ssm.put_parameter(
            Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"],
            Value=json.dumps({"mock-commit-cfg": False}),
        )
        ssm.put_parameter(Name=os.environ["GITHUB_TOKEN_SSM_KEY"], Value="mock-token")
        yield ssm_context


@pytest.fixture
def ecs_tasks():
    with mock_ecs() as ecs_context:
        ecs = boto3.client("ecs")

        cluster_arn = ecs.create_cluster()["cluster"]["clusterArn"]
        os.environ["ECS_CLUSTER_ARN"] = cluster_arn
        os.environ["PR_PLAN_TASK_CONTAINER_NAME"] = "mock-pr-plan"
        os.environ[
            "CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME"
        ] = "mock-create-deploy-stack"

        task_def = ecs.register_task_definition(
            containerDefinitions=[
                {
                    "name": os.environ["PR_PLAN_TASK_CONTAINER_NAME"],
                    "command": ["/bin/sh"],
                    "cpu": 1,
                    "essential": True,
                    "image": "busybox",
                    "memory": 10,
                    "logConfiguration": {
                        "options": {
                            "awslogs-group": "mock-group",
                            "awslogs-stream-prefix": "mock-prefix",
                        },
                        "logDriver": "awslogs",
                    },
                },
            ],
            family="PrPlan",
            taskRoleArn="arn:aws:iam::12345679012:role/mock-task",
            executionRoleArn="arn:aws:iam::12345679012:role/mock-task-execution",
        )
        os.environ["PR_PLAN_TASK_DEFINITION_ARN"] = task_def["taskDefinition"][
            "taskDefinitionArn"
        ]

        task_def = ecs.register_task_definition(
            containerDefinitions=[
                {
                    "name": os.environ["CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME"],
                    "command": ["/bin/sh"],
                    "cpu": 1,
                    "essential": True,
                    "image": "busybox",
                    "memory": 10,
                    "logConfiguration": {
                        "options": {
                            "awslogs-group": "mock-group",
                            "awslogs-stream-prefix": "mock-prefix",
                        },
                        "logDriver": "awslogs",
                    },
                },
            ],
            family="CreateDeployStack",
            taskRoleArn="arn:aws:iam::12345679012:role/mock-task",
            executionRoleArn="arn:aws:iam::12345679012:role/mock-task-execution",
        )
        os.environ["CREATE_DEPLOY_STACK_TASK_DEFINITION_ARN"] = task_def[
            "taskDefinition"
        ]["taskDefinitionArn"]

        yield ecs_context


@patch.dict(
    os.environ,
    {
        "ACCOUNT_DIM": json.dumps(
            [
                {
                    "path": "foo",
                    "plan_role_arn": "test-plan-role",
                },
                {
                    "path": "bar",
                    "plan_role_arn": "test-plan-role",
                },
            ]
        ),
        "FILEPATH_PATTERN": r".*\.tf",
        "ECS_NETWORK_CONFIG": "{}",
        "MERGE_LOCK_STATUS_CHECK_NAME": "merge-lock",
        "PR_PLAN_COMMIT_STATUS_CONTEXT": "mock-context",
        "CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT": "mock-context",
    },
)
@pytest.mark.usefixtures("aws_credentials", "ssm_params", "ecs_tasks")
@patch("github.Github")
class TestReceiver:
    def test_handler_invalid_sig(self, mock_gh, open_pr_event):
        from functions.webhook_receiver.lambda_function import handler

        open_pr_event["headers"]["x-hub-signature-256"] = "invalid-sig"
        res = handler(open_pr_event, context)
        assert res["statusCode"] == 403

    def test_invalid_filepaths(self, mock_gh, open_pr_event):
        from functions.webhook_receiver.lambda_function import handler

        mock_gh.get_repo.return_value.compare.return_value.files = [
            MockCompareFile("foo/a.py")
        ]
        res = handler(open_pr_event, context)

        assert res["statusCode"] == 200
        assert (
            json.loads(res["body"])["message"]
            == f"No diff filepath was matched within pattern: {os.environ['FILEPATH_PATTERN']}"
        )

    def test_create_deploy_stack_success(self, mock_gh, merge_event):
        from functions.webhook_receiver.lambda_function import handler

        mock_gh.return_value.get_repo.return_value.compare.return_value.files = [
            MockCompareFile("foo/a.tf"),
            MockCompareFile("bar/b.tf"),
        ]

        ecs = boto3.client("ecs")

        res = handler(merge_event, context)
        log.debug(res)
        assert res["statusCode"] == 200

        tasks = ecs.list_tasks(
            cluster=os.environ["ECS_CLUSTER_ARN"], launchType="FARGATE"
        )["taskArns"]

        assert len(tasks) == 1

    def test_pr_plan_success(self, mock_gh, open_pr_event):
        from functions.webhook_receiver.lambda_function import handler

        mock_gh.return_value.get_repo.return_value.compare.return_value.files = [
            MockCompareFile("foo/a.tf"),
            MockCompareFile("bar/b.tf"),
        ]

        ecs = boto3.client("ecs")

        res = handler(open_pr_event, context)
        log.debug(res)
        assert res["statusCode"] == 200

        tasks = ecs.list_tasks(
            cluster=os.environ["ECS_CLUSTER_ARN"], launchType="FARGATE"
        )["taskArns"]

        assert len(tasks) == 2
