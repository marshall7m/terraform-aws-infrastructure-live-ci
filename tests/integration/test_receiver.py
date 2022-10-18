import os
import json
import random
import hmac
import hashlib

import pytest
from fastapi.testclient import TestClient
from unittest.mock import patch
from functions.webhook_receiver.lambda_function import handler
from moto import mock_ssm, mock_ecs
import boto3

client = TestClient(handler.app)


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

with open(os.path.join(os.path.dirname(__file__), "mock_base_event.json"), "r") as f:
    base_event = json.load(f)


@pytest.fixture()
def event():
    event = base_event.copy()
    valid_sig = hmac.new(
        bytes(str(mock_gh_wh_secret), "utf-8"),
        bytes(str(event.get("body")), "utf-8"),
        hashlib.sha256,
    ).hexdigest()

    event["headers"]["x-hub-signature-256"] = "sha256=" + valid_sig

    return event


# @pytest.fixture
# def ssm_params():
#   _environ = os.environ.copy()
#   def _set():
#     os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"] = "mock-secret-key"
#     os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"] = "mock-commit-status-key"
#     os.environ["GITHUB_TOKEN_SSM_KEY"] = "mock-token-key"

#     ssm = boto3.client("ssm")

#     ssm.put_parameter(Name=os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"], Value=mock_gh_wh_secret)
#     ssm.put_parameter(Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"], Value=json.dumps({"mock-commit-cfg": False}))
#     ssm.put_parameter(Name=os.environ["GITHUB_TOKEN_SSM_KEY"], Value="mock-token")

#   yield _set

#   os.environ.clear()
#   os.environ.update(_environ)


@pytest.fixture
def ssm_params():
    with mock_ssm() as ssm_context:
        os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"] = "mock-secret-key"
        os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"] = "mock-commit-status-key"
        os.environ["GITHUB_TOKEN_SSM_KEY"] = "mock-token-key"

        ssm = boto3.client("ssm")

        ssm.put_parameter(
            Name=os.environ["GITHUB_WEBHOOK_SECRET_SSM_KEY"], Value=mock_gh_wh_secret
        )
        ssm.put_parameter(
            Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"],
            Value=json.dumps({"mock-commit-cfg": False}),
        )
        ssm.put_parameter(Name=os.environ["GITHUB_TOKEN_SSM_KEY"], Value="mock-token")
        yield ssm_context


@mock_ecs
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
        "ECS_CLUSTER_ARN": "mock-ecs-cluster-arn",
        "ECS_NETWORK_CONFIG": "{}",
        "PR_PLAN_TASK_CONTAINER_NAME": "mock-container-name",
        "PR_PLAN_COMMIT_STATUS_CONTEXT": "mock-context",
        "PR_PLAN_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
        "CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME": "mock-container-name",
        "CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT": "mock-context",
        "CREATE_DEPLOY_STACK_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
    },
)
@pytest.mark.usefixtures("aws_credentials", "ssm_params")
@patch("github.Github.get_repo")
class TestReceiver:
    def test_handler_invalid_sig(self, event):
        event["headers"]["x-hub-signature-256"] = "invalid-sig"
        res = handler(base_event, context)

        assert res["statusCode"] == 403

    def test_invalid_filepaths(self, mock_gh, event):
        mock_gh.get_repo.return_value.compare.return_value.files = [
            MockCompareFile("foo/a.py")
        ]
        res = handler(event, context)

        assert res["statusCode"] == 200
        assert (
            json.loads(res["body"])
            == f"No diff filepath was matched within pattern: {os.environ['FILEPATH_PATTERN']}"
        )

    @pytest.mark.skip()
    def test_trigger_pr_plan_success(self, mock_gh):
        mock_gh.get_repo.return_value.compare.return_value.files = [
            MockCompareFile("foo/a.tf"),
            MockCompareFile("bar/b.tf"),
        ]

        ecs = boto3.client("ecs")
        ecs.register_task_definition = {
            "taskDefinition": {
                "containerDefinitions": [
                    {
                        "logConfiguration": {
                            "options": {
                                "awslogs-group": "mock-group",
                                "awslogs-stream-prefix": "mock-prefix",
                            }
                        }
                    }
                ]
            }
        }
        event["body"] = json.dumps({})
        res = handler(event, context)
        assert res["statusCode"] == 200

        # assert correct amount of task are running
        ecs.list_tasks()

        # get commit statuses and assert contains one for each dir
        # assert_commit_status_state(mock_gh, "pending", "Merge Lock")

    @pytest.mark.skip()
    def test_trigger_pr_plan_failure(self, mock_gh):
        # create case where task def doesn't exist during RunTask call?
        pass

    @pytest.mark.skip()
    def test_trigger_create_deploy_stack(self, mock_gh):
        pass

    @pytest.mark.skip()
    def test_trigger_create_deploy_failure(self, mock_gh):
        pass
