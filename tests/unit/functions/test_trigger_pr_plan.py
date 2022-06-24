import pytest
import os
import logging
import json
import uuid
import github
from unittest.mock import patch
from tests.helpers.utils import dummy_tf_output
from functions.trigger_pr_plan.lambda_function import lambda_handler

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class ServerException(Exception):
    pass


account_dim = [
    {"path": "directory_dependency/dev-account", "plan_role_arn": "test-plan-role"},
    {
        "path": "directory_dependency/shared-services-account",
        "plan_role_arn": "test-plan-role",
    },
]


@pytest.fixture(scope="module")
def pr(repo, request):

    base_commit = repo.get_branch(request.param["base_ref"])
    head_ref = repo.create_git_ref(
        ref="refs/heads/" + request.param["head_ref"], sha=base_commit.commit.sha
    )
    elements = []
    for filepath, content in request.param["changes"].items():
        log.debug(f"Creating file: {filepath}")
        blob = repo.create_git_blob(content, "utf-8")
        elements.append(
            github.InputGitTreeElement(
                path=filepath, mode="100644", type="blob", sha=blob.sha
            )
        )

    head_sha = repo.get_branch(request.param["head_ref"]).commit.sha
    base_tree = repo.get_git_tree(sha=head_sha)
    tree = repo.create_git_tree(elements, base_tree)
    parent = repo.get_git_commit(sha=head_sha)
    commit_id = repo.create_git_commit(
        request.param.get("commit_message", "Adding test files"), tree, [parent]
    ).sha
    head_ref.edit(sha=commit_id)

    log.info("Creating PR")
    pr = repo.create_pull(
        title=request.param.get("title", f"test-{request.param['head_ref']}"),
        body=request.param.get("body", "Test PR"),
        base=request.param["base_ref"],
        head=request.param["head_ref"],
    )

    yield {
        "number": pr.number,
        "head_commit_id": commit_id,
        "base_ref": request.param["base_ref"],
        "head_ref": request.param["head_ref"],
    }

    log.info(f"Removing PR head ref branch: {request.param['head_ref']}")
    head_ref.delete()

    log.info(f"Closing PR: #{pr.number}")
    try:
        pr.edit(state="closed")
    except Exception:
        log.info("PR is merged or already closed")


@pytest.fixture(scope="module")
def event(pr, repo):
    yield {
        "requestPayload": {
            "body": json.dumps(
                {
                    "compare_url": repo.compare_url.format(
                        base=pr["base_ref"], head=pr["head_ref"]
                    ),
                    "pull_request": {"head": {"sha": pr["head_commit_id"]}},
                    "repository": {"full_name": repo.full_name},
                }
            )
        }
    }


def pytest_generate_tests(metafunc):
    if "pr" in metafunc.fixturenames and "expected_plan_dirs" in metafunc.fixturenames:
        metafunc.parametrize(
            "pr,expected_plan_dirs",
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
                    [
                        "directory_dependency/dev-account/us-west-2/env-one/doo",
                        "directory_dependency/dev-account/global",
                    ],
                )
            ],
            scope="module",
            indirect=["pr"],
        )
    if "repo" in metafunc.fixturenames:
        metafunc.parametrize(
            "repo",
            [f"mut-terraform-aws-infrastructure-{os.path.basename(__file__)}"],
            scope="module",
            indirect=True,
        )


@patch.dict(
    os.environ,
    {
        "ACCOUNT_DIM": json.dumps(account_dim),
        "GITHUB_TOKEN_SSM_KEY": "mock-ssm-key",
        "ECS_CLUSTER_ARN": "mock-ecs-cluster-arn",
        "ECS_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
    },
)
@patch("requests.post")
@patch("functions.trigger_pr_plan.lambda_function.ecs")
@patch(
    "functions.trigger_pr_plan.lambda_function.ssm.get_parameter",
    return_value={
        "Parameter": {"Value": os.environ["TF_VAR_testing_unit_github_token"]}
    },
)
def test_diff_paths(mock_ssm, mock_ecs, mock_requests, pr, expected_plan_dirs, event):
    """
    Creates a PR within a dummy GitHub repo, requests the compare URL,
    m
    """

    # mock_ssm.get_parameter.return_value = {"Parameter": {"Value": os.environ["TF_VAR_testing_unit_github_token"]}}
    log.info("Running Lambda Function")
    lambda_handler(
        event,
        {
            "log_group_name": "mock-log-group-name",
            "log_stream_name": "mock-log-stream-name",
        },
    )

    log.info("Assert ECS run_task() cmd was runned for every expected directory")
    assert len(mock_ecs.run_task.call_args_list) == len(expected_plan_dirs)


@patch.dict(
    os.environ,
    {
        "ACCOUNT_DIM": json.dumps(account_dim),
        "GITHUB_TOKEN_SSM_KEY": "mock-ssm-key",
        "ECS_CLUSTER_ARN": "mock-ecs-cluster-arn",
        "ECS_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
    },
)
@patch("functions.trigger_pr_plan.lambda_function.ecs")
@patch(
    "functions.trigger_pr_plan.lambda_function.ssm.get_parameter",
    return_value={
        "Parameter": {"Value": os.environ["TF_VAR_testing_unit_github_token"]}
    },
)
def test_task_failed_commit_status(
    mock_ssm, mock_ecs, event, repo, pr, expected_plan_dirs
):

    mock_ecs.run_task.side_effect = ServerException("Invalid task")

    log.info("Running Lambda Function")
    lambda_handler(
        event,
        {
            "log_group_name": "mock-log-group-name",
            "log_stream_name": "mock-log-stream-name",
        },
    )

    states = [
        status.state for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
    ]

    log.info("Assert count of commit statuses equals the expected count")
    assert len(expected_plan_dirs) == len(states)

    log.info("Assert PR commit states are valid")
    for state in states:
        assert state == "failure"


@patch.dict(
    os.environ,
    {
        "ACCOUNT_DIM": json.dumps(account_dim),
        "GITHUB_TOKEN_SSM_KEY": "mock-ssm-key",
        "ECS_CLUSTER_ARN": "mock-ecs-cluster-arn",
        "ECS_TASK_DEFINITION_ARN": "mock-ecs-task-def-arn",
    },
)
@patch("functions.trigger_pr_plan.lambda_function.ecs")
@patch(
    "functions.trigger_pr_plan.lambda_function.ssm.get_parameter",
    return_value={
        "Parameter": {"Value": os.environ["TF_VAR_testing_unit_github_token"]}
    },
)
def test_task_pending_commit_status(
    mock_ssm, mock_ecs, event, repo, pr, expected_plan_dirs
):

    log.info("Running Lambda Function")
    lambda_handler(
        event,
        {
            "log_group_name": "mock-log-group-name",
            "log_stream_name": "mock-log-stream-name",
        },
    )

    states = [
        status.state for status in repo.get_commit(pr["head_commit_id"]).get_statuses()
    ]

    log.info("Assert count of commit statuses equals the expected count")
    assert len(expected_plan_dirs) == len(states)

    log.info("Assert PR commit states are valid")
    for state in states:
        assert state == "pending"
