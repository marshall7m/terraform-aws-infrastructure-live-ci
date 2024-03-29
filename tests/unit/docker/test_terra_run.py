import os
import logging
from subprocess import CalledProcessError
import json
from unittest.mock import patch, call

import aurora_data_api
import pytest

from docker.src.common.utils import ServerException, subprocess_run
from docker.src.terra_run.run import (
    update_new_resources,
    get_new_provider_resources,
    main,
    comment_terra_run_plan,
)
from tests.helpers.utils import null_provider_resource, insert_records, rds_data_client
from tests.unit.docker.conftest import mock_subprocess_run

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture(autouse=True)
def git_repo_cwd(git_repo):
    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse("--show-toplevel")
    os.chdir(git_root)
    return git_root


@patch.dict(
    os.environ,
    {
        "TG_BACKEND": "local",
        "NEW_PROVIDERS": '["test-provider"]',
        "IS_ROLLBACK": "false",
        "ROLE_ARN": "tf-role-arn",
    },
)
@patch(
    "docker.src.terra_run.run.subprocess_run",
    side_effect=mock_subprocess_run,
)
@pytest.mark.usefixtures("terraform_version", "terragrunt_version")
@pytest.mark.parametrize(
    "repo_changes,new_providers,expected",
    [
        pytest.param(
            {
                "directory_dependency/dev-account/us-west-2/env-one/doo/a.tf": null_provider_resource
            },
            ["registry.terraform.io/hashicorp/null"],
            ["null_resource.this"],
            id="new_resource_exists",
        ),
        pytest.param(
            {"directory_dependency/dev-account/us-west-2/env-one/doo/a.tf": ""},
            ["registry.terraform.io/hashicorp/null"],
            [],
            id="new_resource_not_exists",
        ),
    ],
    indirect=["repo_changes"],
)
def test_get_new_provider_resources(mock_run, repo_changes, new_providers, expected):
    target_path = os.path.dirname(list(repo_changes.keys())[0])
    log.info("Terraform applying repo changes to update Terraform state file")
    subprocess_run(
        f"terragrunt apply --terragrunt-working-dir {target_path} -auto-approve"
    )

    actual = get_new_provider_resources(target_path, new_providers)

    assert actual == expected


@patch.dict(
    os.environ,
    {
        "TG_BACKEND": "local",
        "EXECUTION_ID": "test-id",
        "TG_COMMAND": "",
        "CFG_PATH": "test/dir",
        "NEW_PROVIDERS": '["test-provider"]',
        "IS_ROLLBACK": "false",
        "ROLE_ARN": "tf-role-arn",
    },
)
@patch("docker.src.terra_run.run.get_new_provider_resources")
@pytest.mark.usefixtures("aws_credentials", "truncate_executions")
@pytest.mark.parametrize(
    "resources",
    [
        pytest.param(["test.this"], id="one_resource"),
        pytest.param(["test.this", "test.that"], id="multiple_resources"),
        pytest.param([], id="no_resources"),
    ],
)
def test_update_new_resources(mock_get_new_provider_resources, resources):
    """Assert that the expected new_resources value is within the associated record"""

    insert_records(
        "executions",
        [{"execution_id": os.environ["EXECUTION_ID"]}],
        enable_defaults=True,
    )

    mock_get_new_provider_resources.return_value = resources

    update_new_resources()

    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT new_resources
            FROM executions
            WHERE execution_id = '{os.environ["EXECUTION_ID"]}'
        """
        )
        res = cur.fetchone()[0]

    log.debug(f"Results:\n{res}")

    log.info(
        "Assert that the expected new_resources value is within the associated record"
    )
    assert res == resources


@pytest.mark.parametrize(
    "state_name,expected_status,run_side_effect,update_new_resources_side_effect",
    [
        pytest.param("Plan", "success", None, None, id="plan_run_succeed"),
        pytest.param("Apply", "success", None, None, id="all_succeed"),
        pytest.param(
            "Apply",
            "failure",
            CalledProcessError(1, ""),
            None,
            id="update_resources_failed",
        ),
        pytest.param(
            "Apply",
            "failure",
            CalledProcessError(1, ""),
            ServerException("Function failed"),
            id="all_failed",
        ),
    ],
)
@patch.dict(
    os.environ,
    {
        "TG_COMMAND": "",
        "COMMIT_STATUS_CONFIG": json.dumps({"Plan": True, "Apply": True}),
        "TASK_TOKEN": "token-123",
    },
)
@patch("docker.src.terra_run.run.get_task_log_url")
@patch("docker.src.terra_run.run.send_commit_status")
@patch("docker.src.terra_run.run.update_new_resources")
@patch("subprocess.run")
@patch("boto3.client")
def test_main(
    mock_boto3_client,
    mock_subprocess,
    mock_update_new_resources,
    mock_send_commit_status,
    mock_get_task_log_url,
    state_name,
    expected_status,
    run_side_effect,
    update_new_resources_side_effect,
):
    """Ensures that the correct commit status state is sent depending on the results of upstream processes"""
    os.environ["STATE_NAME"] = state_name

    mock_subprocess.side_effect = run_side_effect
    mock_update_new_resources.side_effect = update_new_resources_side_effect
    log_url = "mock-url"
    mock_get_task_log_url.return_value = log_url

    main()
    assert mock_send_commit_status.call_args_list == [call(expected_status, log_url)]


@patch("github.Github")
@patch.dict(
    os.environ,
    {
        "CFG_PATH": "terraform/cfg",
        "EXECUTION_ID": "run-123",
        "REPO_FULL_NAME": "user/repo",
        "PR_ID": "1",
    },
)
def test_comment_terra_run_plan(mock_gh):
    """Ensures comment_terra_run_plan() formats the comment's diff block properly and returns the expected comment"""
    plan = """

Changes to Outputs:
  - bar = "old" -> null
  + baz = "new"
  ~ foo = "old" -> "new"

You can apply this plan to save these new output values to the Terraform
state, without changing any real infrastructure.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.

"""
    expected = """
## Deployment Infrastructure Changes
### Directory: terraform/cfg
### Execution ID: run-123
<details open>
<summary>Plan</summary>
<br>

``` diff


Changes to Outputs:
-   bar = "old" -> null
+   baz = "new"
!   foo = "old" -> "new"

You can apply this plan to save these new output values to the Terraform
state, without changing any real infrastructure.

─────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't
guarantee to take exactly these actions if you run "terraform apply" now.


```

</details>
"""
    actual = comment_terra_run_plan(plan)

    assert actual == expected
