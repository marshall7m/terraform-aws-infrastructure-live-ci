import pytest
from mock import Mock
import os
import logging
from unittest.mock import patch
import uuid
import git
import json
import aurora_data_api
from tests.helpers.utils import (
    dummy_configured_provider_resource,
    rds_data_client,
    push,
)
from tests.unit.docker.conftest import mock_subprocess_run
from docker.src.create_deploy_stack.create_deploy_stack import CreateStack  # noqa: E402

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

task = CreateStack()


def pytest_generate_tests(metafunc):
    # creates a dummy remote repo using the following parametrized value
    if "repo" in metafunc.fixturenames:
        metafunc.parametrize(
            "repo",
            [
                {
                    "name": "marshall7m/infrastructure-live-testing-template",
                    "is_fork": True,
                }
            ],
            scope="module",
            indirect=True,
        )


@patch.dict(os.environ, {"TG_BACKEND": "local"})
@patch(
    "docker.src.create_deploy_stack.create_deploy_stack.subprocess_run",
    side_effect=mock_subprocess_run,
)
@pytest.mark.usefixtures("terraform_version", "terragrunt_version")
def test_get_new_providers(mock_run, repo, tmp_path_factory):
    """
    Ensures get_new_providers() parses the Terragrunt command properly
    to extract the existing and new Terraform providers
    """
    git_root = str(tmp_path_factory.mktemp(f"test-{uuid.uuid4()}"))
    branch = f"test-{uuid.uuid4()}"
    path = "directory_dependency/dev-account/global"
    push(
        repo=repo,
        branch=branch,
        changes={f"{path}/b.tf": dummy_configured_provider_resource},
    )
    git.Repo.clone_from(repo.clone_url, git_root, branch=branch)

    actual = task.get_new_providers(f"{git_root}/{path}", "mock-role-arn")
    assert actual == ["registry.terraform.io/marshall7m/dummy"]


@patch.dict(os.environ, {"TG_BACKEND": "local"})
@pytest.mark.usefixtures("terraform_version", "terragrunt_version")
def test_get_graph_deps(tmp_path_factory, repo):
    """
    Ensures get_graph_deps() parses the Terragrunt command properly
    to transform the command output into a Python dictionary
    """
    git_root = str(tmp_path_factory.mktemp(f"test-{uuid.uuid4()}"))
    os.environ["SOURCE_REPO_PATH"] = git_root

    git.Repo.clone_from(
        repo.clone_url,
        git_root,
    )
    # need to cd into git dir in order for directories within Terragrunt
    # command output to be relative to git root
    os.chdir(git_root)
    actual = task.get_graph_deps(
        git_root + "/directory_dependency/dev-account", "mock-role-arn"
    )

    assert actual == {
        "global": [],
        "us-west-2/env-one/bar": ["us-west-2/env-one/baz", "global"],
        "us-west-2/env-one/baz": ["global"],
        "us-west-2/env-one/doo": ["global"],
        "us-west-2/env-one/foo": ["us-west-2/env-one/bar"],
    }


@patch.dict(
    os.environ,
    {
        "TG_BACKEND": "local",
        "GITHUB_TOKEN": os.environ["TF_VAR_testing_unit_github_token"],
    },
)
def test_get_github_diff_paths(repo, tmp_path_factory):
    """
    Ensures get_github_diff_paths() returns the expected list of
    diff directories using the GitHub API and Terragrunt graph-dependencies
    dictionary
    """
    os.environ["REPO_FULL_NAME"] = repo.full_name
    git_root = str(tmp_path_factory.mktemp(f"test-{uuid.uuid4()}"))
    os.environ["SOURCE_REPO_PATH"] = git_root
    branch = f"test-{uuid.uuid4()}"
    path = "directory_dependency/dev-account/global"

    push(
        repo=repo,
        branch=branch,
        changes={
            "directory_dependency/dev-account/global/b.tf": dummy_configured_provider_resource
        },
    )
    os.environ["COMMIT_ID"] = repo.get_branch(branch).commit.sha

    git.Repo.clone_from(repo.clone_url, git_root, branch=branch)
    # need to cd into git dir in order for directories within Terragrunt
    # command output to be relative to git root
    os.chdir(git_root)

    graph_deps = task.get_graph_deps(
        "directory_dependency/dev-account", "mock-role-arn"
    )
    log.debug(f"Graph deps: {graph_deps}")
    actual = task.get_github_diff_paths(graph_deps, "directory_dependency/dev-account")

    assert sorted(actual) == sorted(
        [
            path,
            "directory_dependency/dev-account/us-west-2/env-one/baz",
            "directory_dependency/dev-account/us-west-2/env-one/doo",
            "directory_dependency/dev-account/us-west-2/env-one/bar",
            "directory_dependency/dev-account/us-west-2/env-one/foo",
        ]
    )


@patch.dict(
    os.environ,
    {
        "TG_BACKEND": "local",
        "GITHUB_TOKEN": os.environ["TF_VAR_testing_unit_github_token"],
    },
)
@patch(
    "docker.src.create_deploy_stack.create_deploy_stack.subprocess_run",
    side_effect=mock_subprocess_run,
)
@pytest.mark.usefixtures("terraform_version", "terragrunt_version")
def test_get_plan_diff_paths(mock_run, repo, tmp_path_factory):
    """
    Ensures get_plan_diff_paths() returns the expected list of
    diff directories using the Terragrunt run-all plan command output
    """
    os.environ["REPO_FULL_NAME"] = repo.full_name
    git_root = str(tmp_path_factory.mktemp(f"test-{uuid.uuid4()}"))
    os.environ["SOURCE_REPO_PATH"] = git_root
    branch = f"test-{uuid.uuid4()}"
    path = "directory_dependency/dev-account/global"

    push(
        repo=repo,
        branch=branch,
        changes={
            "directory_dependency/dev-account/global/b.tf": dummy_configured_provider_resource
        },
    )
    os.environ["COMMIT_ID"] = repo.get_branch(branch).commit.sha

    git.Repo.clone_from(repo.clone_url, git_root, branch=branch)
    # need to cd into git dir in order for directories within Terragrunt
    # command output to be relative to git root
    os.chdir(git_root)

    actual = task.get_plan_diff_paths(
        "directory_dependency/dev-account", "mock-role-arn"
    )

    assert sorted(actual) == sorted(
        [
            path,
            "directory_dependency/dev-account/us-west-2/env-one/baz",
            "directory_dependency/dev-account/us-west-2/env-one/doo",
            "directory_dependency/dev-account/us-west-2/env-one/bar",
            "directory_dependency/dev-account/us-west-2/env-one/foo",
        ]
    )


@patch.dict(os.environ, {"SCAN_TYPE": "graph"})
@pytest.mark.parametrize(
    "path,get_graph_deps,get_github_diff_paths,get_new_providers,expected",
    [
        pytest.param(
            "directory_dependency/dev-account",
            {
                "directory_dependency/dev-account/us-west-2/env-one/doo": [],
                "directory_dependency/dev-account/us-west-2/env-one/baz": [],
                "directory_dependency/dev-account/us-west-2/env-one/foo": [
                    "directory_dependency/dev-account/us-west-2/env-one/baz"
                ],
            },
            [
                "directory_dependency/dev-account/us-west-2/env-one/foo",
                "directory_dependency/dev-account/us-west-2/env-one/baz",
            ],
            ["test/provider"],
            [
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/baz",
                    "cfg_deps": [],
                    "new_providers": ["test/provider"],
                },
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/foo",
                    "cfg_deps": [
                        "directory_dependency/dev-account/us-west-2/env-one/baz"
                    ],
                    "new_providers": ["test/provider"],
                },
            ],
            id="multi_deps",
        ),
        pytest.param(
            "directory_dependency/dev-account",
            {
                "directory_dependency/dev-account/us-west-2/env-one/doo": [],
                "directory_dependency/dev-account/us-west-2/env-one/baz": [],
                "directory_dependency/dev-account/us-west-2/env-one/foo": [
                    "directory_dependency/dev-account/us-west-2/env-one/baz"
                ],
            },
            [
                "directory_dependency/dev-account/us-west-2/env-one/doo",
            ],
            ["test/provider"],
            [
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "cfg_deps": [],
                    "new_providers": ["test/provider"],
                }
            ],
            id="no_deps",
        ),
        pytest.param(
            "directory_dependency/dev-account",
            {
                "directory_dependency/dev-account/us-west-2/env-one/doo": [],
                "directory_dependency/dev-account/us-west-2/env-one/baz": [],
                "directory_dependency/dev-account/us-west-2/env-one/foo": [
                    "directory_dependency/dev-account/us-west-2/env-one/baz"
                ],
            },
            [],
            ["test/provider"],
            [],
            id="no_diff_paths",
        ),
    ],
)
def test_create_stack(
    path, get_graph_deps, get_github_diff_paths, get_new_providers, expected
):
    """
    Ensures create_stack() returns the correct list of directory configurations.
    All mocked dependency methods within create_stack() contain side effects that are
    parameterizable to produce different outcomes.
    """
    with patch.multiple(
        task,
        get_graph_deps=Mock(return_value=get_graph_deps),
        get_github_diff_paths=Mock(return_value=get_github_diff_paths),
        get_new_providers=Mock(return_value=get_new_providers),
    ):
        actual = task.create_stack(path, "mock-role-arn")

        assert actual == expected


@patch.dict(
    os.environ,
    {
        "PR_ID": "1",
        "COMMIT_ID": "commit-1",
        "BASE_REF": "master",
        "HEAD_REF": "feature-1",
    },
)
@pytest.mark.usefixtures("account_dim", "truncate_executions")
@pytest.mark.parametrize(
    "create_stack",
    [
        pytest.param(
            [
                [{"cfg_path": "foo", "cfg_deps": ["bar"], "new_providers": ["baz"]}],
                [{"cfg_path": "foo", "cfg_deps": ["bar"], "new_providers": ["baz"]}],
            ]
        )
    ],
)
def test_update_executions_with_new_deploy_stack_query(create_stack):
    """
    Ensures update_executions_with_new_deploy_stack_query() runs the insert
    query without error. Test includes assertion to ensure that the expected
    count of records are inserted.
    """
    with patch.object(task, "create_stack", side_effect=create_stack):
        task.update_executions_with_new_deploy_stack()
        with aurora_data_api.connect(
            database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
        ) as conn, conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM executions")
            count = cur.fetchone()[0]

        assert count == len(create_stack)


# mock task's env vars
@patch.dict(
    os.environ,
    {
        "BASE_REF": "master",
        "HEAD_REF": "test-feature",
        "STATE_MACHINE_ARN": "mock",
        "GITHUB_MERGE_LOCK_SSM_KEY": "mock-ssm-key",
        "TRIGGER_SF_FUNCTION_NAME": "mock-lambda",
        "TG_BACKEND": "local",
        "PR_ID": "1",
        "COMMIT_ID": "mock-commit-id",
        "COMMIT_STATUS_CONFIG": json.dumps({"CreateDeployStack": True}),
        "STATUS_CHECK_NAME": "foo",
        "GITHUB_TOKEN": "mock-token",
        "REPO_FULL_NAME": "owner/repo",
    },
)
@pytest.mark.parametrize(
    "update_side_effect,expected_state",
    [
        pytest.param(None, "success", id="success"),
        pytest.param(Exception, "failure", id="failure"),
    ],
)
@patch("docker.src.create_deploy_stack.create_deploy_stack.github")
@patch("docker.src.create_deploy_stack.create_deploy_stack.ssm")
@patch("docker.src.create_deploy_stack.create_deploy_stack.lb")
@pytest.mark.usefixtures("aws_credentials")
def test_main(mock_lambda, mock_ssm, mock_github, update_side_effect, expected_state):
    """Ensures main() handles sub-method errors properly"""

    class MockStatus:
        def __init__(self):
            self.target_url = "foo"
            self.context = os.environ["STATUS_CHECK_NAME"]

    mock_status = MockStatus()
    mock_github.Github.return_value.get_repo.return_value.get_commit.return_value.get_statuses.return_value = [
        mock_status
    ]

    with patch.object(
        task, "update_executions_with_new_deploy_stack", side_effect=update_side_effect
    ):
        task.main()

    if expected_state == "failure":
        log.info("Assert merge lock value was reset")
        mock_ssm.put_parameter.assert_called_with(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value="none",
            Type="String",
            Overwrite=True,
        )

        log.info("Assert Lambda Function was not invoked")
        mock_lambda.invoke.assert_not_called()

    elif expected_state == "success":
        log.info("Assert merge lock value was set")
        mock_ssm.put_parameter.assert_called_with(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value=os.environ["PR_ID"],
            Type="String",
            Overwrite=True,
        )

        log.info("Assert Lambda Function was invoked")
        mock_lambda.invoke.assert_called_once()

    else:
        raise Exception(f"Expected state is not handled: {expected_state}")
