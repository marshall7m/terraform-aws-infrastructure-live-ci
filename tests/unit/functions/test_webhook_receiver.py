import logging
import pytest
import os
import json
from unittest.mock import patch, Mock
from functions.webhook_receiver.invoker import Invoker
from functions.webhook_receiver.lambda_function import InvokerHandler, ClientException


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class MockCompareFile:
    def __init__(self, filename, status="added"):
        self.filename = filename
        self.status = status


compare_files = [MockCompareFile("foo/a.tf"), MockCompareFile("bar/b.tf")]


@pytest.fixture()
def app():
    return Invoker()


@pytest.fixture()
def handler(app):
    return InvokerHandler(app=app, secret="mock-secret", token=None)


def assert_commit_status_state(mock_gh, expected_state):
    commit_states = [
        call.kwargs["state"]
        for call in mock_gh.get_repo.return_value.get_branch.return_value.commit.create_status.call_args_list
    ]
    for state in commit_states:
        assert state == expected_state


@patch.dict(
    os.environ,
    {
        "ECS_CLUSTER_ARN": "mock-ecs-cluster-arn",
        "ECS_NETWORK_CONFIG": "{}",
    },
)
@patch("boto3.client")
@patch("github.Github.get_repo")
@pytest.mark.usefixtures("aws_credentials")
class TestInvoker:
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
            "PR_PLAN_TASK_CONTAINER_NAME": "mock-container-name",
            "PR_PLAN_COMMIT_STATUS_CONTEXT": "mock-context",
            "PR_PLAN_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
            "PR_PLAN_LOG_STREAM_PREFIX": "mock-plan-prefix",
            "LOG_URL_PREFIX": "mock-log",
        },
    )
    @pytest.mark.parametrize(
        "expected_state,expected_plan_dirs,run_task_side_effect",
        [
            pytest.param(
                "pending",
                [
                    "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "directory_dependency/dev-account/global",
                ],
                None,
                id="pending_state",
            ),
            pytest.param(
                "failure",
                [
                    "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "directory_dependency/dev-account/global",
                ],
                Exception("Invalid task"),
                id="failure_state",
            ),
        ],
    )
    def test_trigger_pr_plan(
        self,
        mock_gh,
        mock_boto_client,
        app,
        expected_plan_dirs,
        expected_state,
        run_task_side_effect,
    ):
        """
        Setups a PR within a dummy GitHub repo that contains added .hcl/.tf files.
        Test asserts that the Lambda Function executes the ecs run_task() method
        for every unique directory that contains .hcl/.tf file changes. The test
        places a parametrized side effect on the ecs run_task() method. If the
        side effect raises an exception, the Lambda Function is expected to set
        the commit status for every pr plan task to `failure` and `success` if
        not.
        """

        mock_gh.get_repo.return_value.compare.return_value.files = compare_files
        app.gh = mock_gh

        mock_boto_client.return_value = mock_boto_client
        mock_boto_client.describe_task_definition.return_value = {
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

        mock_boto_client.run_task.return_value = {
            "tasks": [{"containers": [{"taskArn": "arn/task-id"}]}]
        }

        mock_boto_client.run_task.side_effect = run_task_side_effect

        app.trigger_pr_plan(
            "mock-repo",
            "master",
            "feature-123",
            "commit-123",
            "https://localhost",
            True,
        )

        log.info("Assert ECS run_task() cmd ran for every expected directory")
        assert len(mock_boto_client.run_task.call_args_list) == len(expected_plan_dirs)

        log.info("Assert PR commit states are valid")
        commit_states = [
            call.kwargs["state"]
            for call in mock_gh.get_repo.return_value.get_branch.return_value.commit.create_status.call_args_list
        ]

        for state in commit_states:
            assert state == expected_state

    @patch.dict(
        os.environ,
        {
            "CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME": "mock-container-name",
            "CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT": "mock-context",
            "CREATE_DEPLOY_STACK_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
        },
    )
    @pytest.mark.parametrize(
        "expected_state,run_task_side_effect",
        [
            pytest.param("pending", None, id="success"),
            pytest.param("failure", Exception("Invalid task"), id="failure"),
        ],
    )
    def test_trigger_create_deploy_stack(
        self, mock_gh, mock_boto_client, app, run_task_side_effect, expected_state
    ):
        """
        Setups a PR within a dummy GitHub repo that contains added .hcl/.tf files.
        The test places a parametrized side effect on the ecs run_task() method.
        If the side effect raises an exception, the Lambda Function is expected
        to set the commit status for the task to `failure` and `success` if not.
        """
        mock_boto_client.return_value = mock_boto_client
        mock_boto_client.run_task.return_value = {
            "tasks": [{"containers": [{"taskArn": "arn/task-id"}]}]
        }

        mock_boto_client.describe_task_definition.return_value = {
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

        mock_boto_client.run_task.side_effect = run_task_side_effect
        app.trigger_create_deploy_stack(
            "mock-repo",
            "master",
            "feature-123",
            "commit-id-123",
            "1",
            "https://localhost",
            True,
        )

        log.info("Assert ECS run_task() cmd ran once")
        assert len(mock_boto_client.run_task.call_args_list) == 1

        log.info(f"Assert commit status is {expected_state}")

        assert_commit_status_state(mock_gh, expected_state)


class TestInvokerHandler:
    @pytest.mark.parametrize(
        "pattern, expected", [(".*\\.tf", True), (".*\\.py", False)]
    )
    @patch("github.Github.get_repo")
    def test_validate_file_paths(self, mock_gh, handler, pattern, expected):
        mock_gh.get_repo.return_value.compare.return_value.files = compare_files
        handler.gh = mock_gh

        is_valid = handler.validate_file_paths(
            "pull_request",
            {
                "body": {
                    "repository": {"full_name": "mock-repo"},
                    "pull_request": {
                        "base": {"sha": "commit-id-1"},
                        "head": {"sha": "commit-id-2"},
                    },
                }
            },
            pattern,
        )

        assert is_valid == expected

    @patch.dict(os.environ, {"BASE_BRANCH": "master", "FILE_PATH_PATTERN": ".+.tf"})
    @patch("functions.webhook_receiver.lambda_function.validate_sig")
    def test_handle_invalid_sig(self, mock_validate_sig, handler):

        mock_validate_sig.side_effect = ClientException("invalid")
        func = Mock()
        event_type = "pull_request"
        handler.app.listeners[event_type] = [{"function": func}]
        response = handler.handle(
            {
                "headers": {
                    "x-hub-signature-256": "sha256=invalid",
                    "x-github-event": event_type,
                },
                "body": json.dumps({"foo": "bar"}),
            },
            {},
        )

        func.assert_not_called()
        assert response["statusCode"] == 402

    @patch("functions.webhook_receiver.lambda_function.validate_sig")
    def test_handle_invalid_event(self, mock_validate_sig, handler):
        func = Mock()
        event_type = "pull_request"
        handler.app.listeners[event_type] = [
            {"function": func, "filter_groups": [{"A": "regex:bar"}]}
        ]
        response = handler.handle(
            {
                "headers": {
                    "x-hub-signature-256": "sha256=123",
                    "x-github-event": event_type,
                },
                "body": json.dumps({"foo": "bar"}),
            },
            {},
        )

        func.assert_not_called()
        assert response["statusCode"] == 200

    @patch("functions.webhook_receiver.lambda_function.validate_sig")
    @patch.dict(os.environ, {"FILE_PATH_PATTERN": "mock-pattern"})
    def test_handle_invalid_file_paths(self, mock_validate_sig, handler):
        func = Mock()
        event_type = "pull_request"
        handler.app.listeners[event_type] = [
            {"function": func, "filter_groups": [{"body.foo": "regex:bar"}]}
        ]

        with patch.object(handler, "validate_file_paths") as mock_validate_file_paths:
            mock_validate_file_paths.return_value = False

            response = handler.handle(
                {
                    "headers": {
                        "x-hub-signature-256": "sha256=123",
                        "x-github-event": event_type,
                    },
                    "body": json.dumps({"foo": "bar"}),
                },
                {},
            )

        func.assert_not_called()
        assert response["statusCode"] == 200

    @patch("functions.webhook_receiver.lambda_function.validate_sig")
    def test_handle_success(self, mock_validate_sig, handler):
        app = Invoker()
        func = Mock()
        event_type = "pull_request"
        handler.app.listeners[event_type] = [
            {"function": func, "filter_groups": [{"body.foo": "regex:bar"}]}
        ]

        invoker = InvokerHandler(app=app, secret="mock-secret", token=None)
        with patch.object(invoker, "validate_file_paths") as mock_validate_file_paths:
            mock_validate_file_paths.return_value = True

            response = handler.handle(
                {
                    "headers": {
                        "x-hub-signature-256": "sha256=123",
                        "x-github-event": event_type,
                    },
                    "body": json.dumps({"foo": "bar"}),
                },
                {},
            )

        func.assert_called_once()
        assert response["statusCode"] == 200
