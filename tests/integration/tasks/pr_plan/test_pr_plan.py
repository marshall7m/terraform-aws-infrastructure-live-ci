import pytest
import os
import github
import logging
import uuid
import json
from tests.helpers.utils import dummy_tf_output
from tests.integration.tasks.helpers.utils import run_task

log = logging.getLogger(__file__)
log.setLevel(logging.DEBUG)
gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])


@pytest.mark.usefixtures("truncate_executions", "terra_setup")
@pytest.mark.parametrize(
    "push_changes",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output(
                    name="1_invalid_name"
                )
            },
            id="invalid_tf_file",
        )
    ],
    indirect=True,
)
def test_successful_execution(mut_output, push_changes):
    cfg_path = os.path.dirname(list(push_changes["changes"].keys())[0])
    run_task(
        mut_output=mut_output,
        task_def_arn=mut_output["ecs_pr_plan_task_definition_arn"],
        compose_files=[
            os.path.join(
                os.path.dirname(__file__), "docker-compose.ecs-local.custom.yml"
            )
        ],
        task_env_vars={
            "REPO_FULL_NAME": mut_output["repo_full_name"],
            "CFG_PATH": cfg_path,
            "COMMIT_ID": push_changes["commit_id"],
            "ROLE_ARN": mut_output["plan_role_arn"],
            "SOURCE_VERSION": push_changes["branch"],
            "STATUS_CHECK_NAME": "Plan: " + cfg_path,
        },
        local_task_env_vars={
            "plan_GITHUB_TOKEN": os.environ["GITHUB_TOKEN"],
            "plan_COMMIT_STATUS_CONFIG": json.dumps(mut_output["commit_status_config"]),
            "BUILD_PATH": os.path.join(os.path.dirname(__file__), "../../../../docker"),
        },
    )

    repo = gh.get_repo(mut_output["repo_full_name"])
    status = [
        status
        for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
        if status.context == mut_output["pr_plan_status_check_name"]
    ][0]

    log.info("Assert that expected commit status state is sent")
    assert status.state == "success"


@pytest.mark.skip()
@pytest.mark.usefixtures("truncate_executions", "terra_setup")
@pytest.mark.parametrize(
    "push_changes",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output(
                    name="1_invalid_name"
                )
            },
            id="invalid_tf_file",
        )
    ],
    indirect=True,
)
def test_failed_execution(mut_output, push_changes):
    with pytest.raises(Exception):
        run_task(
            mut_output=mut_output,
            task_def_arn=mut_output["ecs_pr_plan_task_definition_arn"],
            task_env_vars={
                "REPO_FULL_NAME": mut_output["repo_full_name"],
                "CFG_PATH": list(push_changes["changes"].keys())[0],
                "COMMIT_ID": push_changes["commit_id"],
                "SOURCE_VERSION": push_changes["branch"],
            },
        )

    repo = gh.get_repo(mut_output["repo_full_name"])
    status = [
        status
        for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
        if status.context == mut_output["pr_plan_status_check_name"]
    ][0]

    log.info("Assert that expected commit status state is sent")
    assert status.state == "failure"
