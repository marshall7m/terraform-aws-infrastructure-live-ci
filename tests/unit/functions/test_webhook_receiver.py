import logging
import pytest
import os
import json
from unittest.mock import patch, Mock
import uuid
from tests.helpers.utils import dummy_tf_output
from functions.webhook_receiver.invoker import Invoker
from functions.webhook_receiver.lambda_function import InvokerHandler, ClientException


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_generate_tests(metafunc):
    # creates a dummy remote repo using the following parametrized value
    if "repo" in metafunc.fixturenames:
        metafunc.parametrize(
            "repo",
            [
                f"mut-terraform-aws-infrastructure-{os.path.splitext(os.path.basename(__file__))[0]}"
            ],
            scope="module",
            indirect=True,
        )

    if "pr" in metafunc.fixturenames:
        # each test uses the same dummy PR event
        metafunc.parametrize(
            "pr",
            [
                (
                    {
                        "base_ref": "master",
                        "head_ref": f"feature-{uuid.uuid4()}",
                        "changes": {
                            "directory_dependency/dev-account/us-west-2/env-one/doo/a.tf": dummy_tf_output(),
                            "directory_dependency/dev-account/us-west-2/env-one/doo/b.tf": dummy_tf_output(),
                            "directory_dependency/dev-account/global/a.tf": dummy_tf_output(),
                            "directory_dependency/shared-services-account/global/a.txt": "",
                        },
                        "commit_message": "Adding testing files",
                    },
                )
            ],
            indirect=True,
        )


@pytest.fixture
def invoker(repo, pr, gh):
    """Returns instance of Invoker class"""
    return Invoker(
        token=os.environ["TF_VAR_testing_unit_github_token"],
        commit_status_config={"PrPlan": True, "CreateDeployStack": True},
        gh=gh,
    )


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@patch.dict(
    os.environ,
    {
        "ECS_CLUSTER_ARN": "mock-ecs-cluster-arn",
        "ECS_NETWORK_CONFIG": "{}",
    },
)
@pytest.mark.usefixtures("aws_credentials")
class TestInvoker:
    @patch.dict(
        os.environ,
        {
            "ACCOUNT_DIM": json.dumps(
                [
                    {
                        "path": "directory_dependency/dev-account",
                        "plan_role_arn": "test-plan-role",
                    },
                    {
                        "path": "directory_dependency/shared-services-account",
                        "plan_role_arn": "test-plan-role",
                    },
                ]
            ),
            "PR_PLAN_TASK_CONTAINER_NAME": "mock-container-name",
            "PR_PLAN_COMMIT_STATUS_CONTEXT": "mock-context",
            "PR_PLAN_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
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
    @patch("functions.webhook_receiver.invoker.ecs")
    def test_trigger_pr_plan(
        self,
        mock_ecs,
        repo,
        pr,
        invoker,
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
        mock_ecs.describe_task_definition.return_value = {
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

        mock_ecs.run_task.return_value = {
            "tasks": [{"containers": [{"taskArn": "arn/task-id"}]}]
        }

        mock_ecs.run_task.side_effect = run_task_side_effect
        repo.get_branch("master").edit_protection(contexts=["foo"])

        invoker.trigger_pr_plan(
            repo.full_name,
            "master",
            pr["head_ref"],
            pr["head_commit_id"],
            "https://localhost",
            True,
        )

        log.info("Assert ECS run_task() cmd ran for every expected directory")
        assert len(mock_ecs.run_task.call_args_list) == len(expected_plan_dirs)

        log.info("Assert PR commit states are valid")
        states = [
            status.state
            for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
        ]
        for state in states:
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
        "expected_status,run_task_side_effect",
        [
            pytest.param("pending", None, id="success"),
            pytest.param("failure", Exception("Invalid task"), id="failure"),
        ],
    )
    @patch("functions.webhook_receiver.invoker.ecs")
    def test_trigger_create_deploy_stack(
        self, mock_ecs, invoker, repo, pr, run_task_side_effect, expected_status
    ):
        """
        Setups a PR within a dummy GitHub repo that contains added .hcl/.tf files.
        The test places a parametrized side effect on the ecs run_task() method.
        If the side effect raises an exception, the Lambda Function is expected
        to set the commit status for the task to `failure` and `success` if not.
        """
        mock_ecs.run_task.return_value = {
            "tasks": [{"containers": [{"taskArn": "arn/task-id"}]}]
        }

        mock_ecs.describe_task_definition.return_value = {
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

        mock_ecs.run_task.side_effect = run_task_side_effect
        invoker.trigger_create_deploy_stack(
            repo.full_name,
            pr["base_ref"],
            pr["head_ref"],
            pr["head_commit_id"],
            pr["number"],
            "https://localhost",
            True,
        )

        log.info("Assert ECS run_task() cmd ran once")
        assert len(mock_ecs.run_task.call_args_list) == 1

        log.info(f"Assert commit status is {expected_status}")
        states = [
            status.state
            for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
        ]

        assert states == [expected_status]


def test_handler_invalid_headers():
    pass


@patch.dict(os.environ, {"BASE_BRANCH": "master", "FILE_PATH_PATTERN": ".+.tf"})
@patch("functions.webhook_receiver.lambda_function.validate_sig")
def test_handle_invalid_sig(mock_validate_sig):

    mock_validate_sig.side_effect = ClientException("invalid")
    app = Invoker()
    func = Mock()
    event_type = "pull_request"
    app.listeners[event_type] = [{"function": func}]

    invoker = InvokerHandler(app=app, secret="mock-secret")
    response = invoker.handle(
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
def test_handle_invalid_event(mock_validate_sig):
    app = Invoker()
    func = Mock()
    event_type = "pull_request"
    app.listeners[event_type] = [
        {"function": func, "filter_groups": [{"A": "regex:bar"}]}
    ]

    invoker = InvokerHandler(app=app, secret="mock-secret")
    response = invoker.handle(
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
def test_handle_invalid_file_paths(mock_validate_sig):
    app = Invoker()
    func = Mock()
    event_type = "pull_request"
    app.listeners[event_type] = [
        {"function": func, "filter_groups": [{"body.foo": "regex:bar"}]}
    ]

    invoker = InvokerHandler(app=app, secret="mock-secret")
    with patch.object(invoker, "validate_file_paths") as mock_validate_file_paths:
        mock_validate_file_paths.return_value = False

        response = invoker.handle(
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
def test_handle_success(mock_validate_sig):
    app = Invoker()
    func = Mock()
    event_type = "pull_request"
    app.listeners[event_type] = [
        {"function": func, "filter_groups": [{"body.foo": "regex:bar"}]}
    ]

    invoker = InvokerHandler(app=app, secret="mock-secret")
    with patch.object(invoker, "validate_file_paths") as mock_validate_file_paths:
        mock_validate_file_paths.return_value = True

        response = invoker.handle(
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


@pytest.mark.parametrize("pattern, expected", [(".*\\.tf", True), (".*\\.py", False)])
def test_validate_file_paths(repo, pr, gh, pattern, expected):
    invoker = InvokerHandler(app=Mock(), secret="mock-secret")
    invoker.gh = gh
    is_valid = invoker.validate_file_paths(
        "pull_request",
        {
            "body": {
                "repository": {"full_name": repo.full_name},
                "pull_request": {
                    "base": {"ref": pr["base_ref"]},
                    "head": {"ref": pr["head_ref"]},
                },
            }
        },
        pattern,
    )

    assert is_valid == expected
