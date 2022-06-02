import pytest
import os
import logging
from unittest.mock import patch
import uuid
from tests.helpers.utils import dummy_tf_output, null_provider_resource
from tests.unit.buildspecs.conftest import mock_subprocess_run

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def scan_type_idfn(val):
    if val:
        return "graph_scan"
    else:
        return "plan_scan"


@pytest.fixture(
    params=[pytest.param(True), pytest.param(False, marks=pytest.mark.skip())],
    ids=scan_type_idfn,
)
def scan_type(request):
    """Determiens if Terragrun graph depedencies or run-all plan command is used to detect directories with differences"""
    if request.param:
        os.environ["GRAPH_SCAN"] = "true"
    yield None

    if "GRAPH_SCAN" in os.environ:
        del os.environ["GRAPH_SCAN"]


@pytest.mark.parametrize(
    "repo_changes,expected_stack",
    [
        pytest.param(
            {
                "directory_dependency/dev-account/us-west-2/env-one/doo/a.tf": dummy_tf_output()
            },
            [
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "cfg_deps": [],
                    "new_providers": [],
                }
            ],
            id="no_deps",
        ),
        pytest.param(
            {
                "directory_dependency/dev-account/us-west-2/env-one/doo/a.tf": null_provider_resource
            },
            [
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "cfg_deps": [],
                    "new_providers": ["registry.terraform.io/hashicorp/null"],
                }
            ],
            id="no_deps_new_provider",
        ),
        pytest.param(
            {"directory_dependency/dev-account/global/a.tf": dummy_tf_output()},
            [
                {
                    "cfg_path": "directory_dependency/dev-account/global",
                    "cfg_deps": [],
                    "new_providers": [],
                },
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "cfg_deps": ["directory_dependency/dev-account/global"],
                    "new_providers": [],
                },
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/baz",
                    "cfg_deps": ["directory_dependency/dev-account/global"],
                    "new_providers": [],
                },
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/bar",
                    "cfg_deps": [
                        "directory_dependency/dev-account/us-west-2/env-one/baz",
                        "directory_dependency/dev-account/global",
                    ],
                    "new_providers": [],
                },
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/foo",
                    "cfg_deps": [
                        "directory_dependency/dev-account/us-west-2/env-one/bar"
                    ],
                    "new_providers": [],
                },
            ],
            id="multi_deps",
        ),
    ],
    indirect=["repo_changes"],
)
@patch.dict(os.environ, {"TG_BACKEND": "local", "CODEBUILD_WEBHOOK_BASE_REF": "master"})
@patch("buildspecs.subprocess_run", side_effect=mock_subprocess_run)
@pytest.mark.usefixtures(
    "aws_credentials", "terraform_version", "terragrunt_version", "scan_type"
)
def test_create_stack(mock_run, git_repo, repo_changes, expected_stack):
    """
    Ensures that create_stack() parses the Terragrunt command output correctly,
    filters out any directories that don't have changes and detects any new
    providers introduced within the configurations
    """
    from buildspecs.create_deploy_stack.create_deploy_stack import CreateStack

    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse("--show-toplevel")
    os.chdir(git_root)

    test_branch = git_repo.create_head(f"test-{uuid.uuid4()}").checkout().repo
    test_branch.index.add(list(repo_changes.keys()))
    commit = test_branch.index.commit("Add terraform testing changes")

    os.environ["CODEBUILD_RESOLVED_SOURCE_VERSION"] = commit.hexsha

    log.debug("Running create_stack()")
    create_stack = CreateStack()
    # for sake of testing, using just one account directory
    stack = create_stack.create_stack(
        "directory_dependency/dev-account", "plan-role-arn"
    )

    log.debug(f"Stack:\n{stack}")
    # convert list of dict to list of list of tuples since dict are not ordered
    assert sorted(sorted(cfg.items()) for cfg in stack) == sorted(
        sorted(cfg.items()) for cfg in expected_stack
    )


# mock codebuild env vars
@patch.dict(
    os.environ,
    {
        "CODEBUILD_INITIATOR": "GitHub-Hookshot/test",
        "CODEBUILD_WEBHOOK_TRIGGER": "pr/1",
        "CODEBUILD_RESOLVED_SOURCE_VERSION": "test-commit",
        "CODEBUILD_WEBHOOK_BASE_REF": "master",
        "CODEBUILD_WEBHOOK_HEAD_REF": "test-feature",
        "METADB_CLUSTER_ARN": "mock",
        "METADB_SECRET_ARN": "mock",
        "METADB_NAME": "mock",
        "STATE_MACHINE_ARN": "mock",
        "GITHUB_MERGE_LOCK_SSM_KEY": "mock-ssm-key",
        "TRIGGER_SF_FUNCTION_NAME": "mock-lambda",
        "TG_BACKEND": "local",
    },
)
@patch(
    "buildspecs.create_deploy_stack.create_deploy_stack.subprocess_run",
    side_effect=mock_subprocess_run,
)
@patch("buildspecs.create_deploy_stack.create_deploy_stack.ssm")
@patch("buildspecs.create_deploy_stack.create_deploy_stack.lb")
@patch("aurora_data_api.connect")
@pytest.mark.usefixtures("aws_credentials")
@pytest.mark.parametrize(
    "repo_changes,accounts,scan_type,expected_failure",
    [
        pytest.param(
            {"directory_dependency/dev-account/global/a.tf": dummy_tf_output()},
            [("directory_dependency/dev-account", "mock-plan-role-arn")],
            True,
            False,
            id="no_deps",
        ),
        pytest.param(
            {"directory_dependency/dev-account/global/a.tf": dummy_tf_output()},
            [("directory_dependency/invalid-account", "mock-plan-role-arn")],
            True,
            True,
            id="invalid_account_path",
        ),
        pytest.param(
            {
                "directory_dependency/dev-account/global/a.tf": dummy_tf_output(
                    name="1_invalid_name"
                ),
                "directory_dependency/shared-services-account/global/a.tf": dummy_tf_output(),
            },
            [
                ("directory_dependency/dev-account", "mock-plan-role-arn"),
                ("directory_dependency/shared-services-account", "mock-plan-role-arn"),
            ],
            False,
            True,
            id="tg_error",
        ),
    ],
    indirect=["repo_changes", "scan_type"],
)
def test_main(
    mock_conn,
    mock_lambda,
    mock_ssm,
    mock_run,
    repo_changes,
    accounts,
    scan_type,
    expected_failure,
    git_repo,
):
    """Ensures main() handles errors properly from top level"""
    from buildspecs.create_deploy_stack.create_deploy_stack import CreateStack

    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse("--show-toplevel")
    os.chdir(git_root)

    test_branch = git_repo.create_head(f"test-{uuid.uuid4()}").checkout().repo
    test_branch.index.add(list(repo_changes.keys()))
    commit = test_branch.index.commit("Add terraform testing changes")

    os.environ["CODEBUILD_RESOLVED_SOURCE_VERSION"] = commit.hexsha

    # get nested aurora.connect() context manager mock
    mock_conn_context = mock_conn.return_value.__enter__.return_value
    # get nested conn.cursor() context manager mock
    mock_cur = mock_conn_context.cursor.return_value.__enter__.return_value
    # mock retrieval of [(account_path, plan_role_arn)] from account dim
    mock_cur.fetchall.return_value = accounts

    create_stack = CreateStack()
    try:
        create_stack.main()
    except Exception as e:
        log.debug(e)

    if expected_failure:
        log.info("Assert execution record creation was rolled back")
        mock_conn_context.rollback.assert_called_once()

        log.info("Assert merge lock value was reset")
        mock_ssm.put_parameter.assert_called_with(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value="none",
            Type="String",
            Overwrite=True,
        )

        log.info("Assert Lambda Function was not invoked")
        mock_lambda.invoke.assert_not_called()
    else:
        log.info("Assert execution record creation was not rolled back")
        mock_cur.rollback.assert_not_called()

        log.info("Assert merge lock value was set")
        mock_ssm.put_parameter.assert_called_with(
            Name=os.environ["GITHUB_MERGE_LOCK_SSM_KEY"],
            Value=os.environ["CODEBUILD_WEBHOOK_TRIGGER"].split("/")[1],
            Type="String",
            Overwrite=True,
        )

        log.info("Assert Lambda Function was invoked")
        mock_lambda.invoke.assert_called_once()
