import logging
import pytest
import os
import json
from unittest.mock import patch
import uuid
import github
from tests.helpers.utils import dummy_tf_output
from functions.webhook_receiver.lambda_function import Invoker, lambda_handler

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
                    },
                )
            ],
            indirect=True,
        )


class ServerException(Exception):
    pass


@pytest.fixture
def pr(repo, request):
    """
    Creates the PR used for testing the function calls to the GitHub API.
    Current implementation creates all PR changes within one commit.
    """

    param = request.param[0]
    base_commit = repo.get_branch(param["base_ref"])
    head_ref = repo.create_git_ref(
        ref="refs/heads/" + param["head_ref"], sha=base_commit.commit.sha
    )
    elements = []
    for filepath, content in param["changes"].items():
        log.debug(f"Creating file: {filepath}")
        blob = repo.create_git_blob(content, "utf-8")
        elements.append(
            github.InputGitTreeElement(
                path=filepath, mode="100644", type="blob", sha=blob.sha
            )
        )

    head_sha = repo.get_branch(param["head_ref"]).commit.sha
    base_tree = repo.get_git_tree(sha=head_sha)
    tree = repo.create_git_tree(elements, base_tree)
    parent = repo.get_git_commit(sha=head_sha)
    commit_id = repo.create_git_commit(
        param.get("commit_message", "Adding test files"), tree, [parent]
    ).sha
    head_ref.edit(sha=commit_id)

    log.info("Creating PR")
    pr = repo.create_pull(
        title=param.get("title", f"test-{param['head_ref']}"),
        body=param.get("body", "Test PR"),
        base=param["base_ref"],
        head=param["head_ref"],
    )

    yield {
        "number": pr.number,
        "head_commit_id": commit_id,
        "base_ref": param["base_ref"],
        "head_ref": param["head_ref"],
    }

    log.info(f"Removing PR head ref branch: {param['head_ref']}")
    head_ref.delete()

    log.info(f"Closing PR: #{pr.number}")
    try:
        pr.edit(state="closed")
    except Exception:
        log.info("PR is merged or already closed")


@pytest.fixture
def invoker(repo, pr):
    """Returns instance of Invoker class"""
    return Invoker(
        os.environ["TF_VAR_testing_unit_github_token"],
        repo.full_name,
        pr["base_ref"],
        pr["head_ref"],
        repo.clone_url,
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
@patch("functions.webhook_receiver.lambda_function.ecs")
class TestWebhookReceiver:
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
                "success",
                [
                    "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "directory_dependency/dev-account/global",
                ],
                None,
                id="success",
            ),
            pytest.param(
                "failure",
                [
                    "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "directory_dependency/dev-account/global",
                ],
                ServerException("Invalid task"),
                id="failure",
            ),
        ],
    )
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
        mock_ecs.run_task.side_effect = run_task_side_effect
        repo.get_branch("master").edit_protection(contexts=["foo"])

        invoker.trigger_pr_plan(True)

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
            pytest.param("failure", ServerException("Invalid task"), id="failure"),
        ],
    )
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
        invoker.trigger_create_deploy_stack("1", True)

        log.info("Assert ECS run_task() cmd ran once")
        assert len(mock_ecs.run_task.call_args_list) == 1

        log.info(f"Assert commit status is {expected_status}")
        states = [
            status.state
            for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
        ]

        assert states == [expected_status]

    @patch.dict(
        os.environ,
        {
            "GITHUB_TOKEN_SSM_KEY": "mock-ssm-token-key",
            "COMMIT_STATUS_CONFIG_SSM_KEY": "mock-ssm-config-key",
        },
    )
    @pytest.mark.parametrize(
        "merged", [pytest.param(True, id="merged"), pytest.param(False, id="open")]
    )
    @patch("functions.webhook_receiver.lambda_function.ssm")
    @patch("functions.webhook_receiver.lambda_function.Invoker")
    def test_lambda_handler(self, mock_invoker, mock_ssm, mock_ecs, merged):
        """Ensures that the correct Invoker method is called for the given GitHub event"""
        mock_ssm.get_parameter.return_value = {
            "Parameter": {
                "Value": json.dumps({"PrPlan": True, "CreateDeployStack": True})
            }
        }

        # mock lambda_handler context object
        class Context:
            def __init__(self):
                self.log_group_name = "test-group"
                self.log_stream_name = "test-stream"

        context = Context()
        lambda_handler(
            {
                "requestPayload": {
                    "body": json.dumps(
                        {
                            "pull_request": {
                                "base": {"ref": "master"},
                                "head": {"ref": "feature"},
                                "number": 1,
                                "merged": merged,
                            },
                            "repository": {"full_name": "user/repo"},
                        }
                    )
                }
            },
            context,
        )

        log.info("Assert that the correct method was called")
        if not merged:
            mock_invoker.return_value.trigger_pr_plan.assert_called_once()
            mock_invoker.return_value.trigger_create_deploy_stack.assert_not_called()
        elif merged:
            mock_invoker.return_value.trigger_create_deploy_stack.assert_called_once()
            mock_invoker.return_value.trigger_pr_plan.assert_not_called()
