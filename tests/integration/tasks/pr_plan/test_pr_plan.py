import pytest
import os
import github
import logging
import uuid
from tests.helpers.utils import dummy_tf_output
from tests.integration.tasks.utils import run_task

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
)
def test_successful_execution(mut_output, push_changes):
    run_task(
        mut_output=mut_output,
        task_def_arn=mut_output["ecs_pr_plan_task_definition_arn"],
        task_env_vars={
            "REPO_FULL_NAME": mut_output["repo_full_name"],
            "STATUS_CHECK_NAME": mut_output["pr_plan_status_check_name"],
            "CFG_PATH": push_changes["branch"],
            "COMMIT_ID": push_changes["commit_id"],
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
)
def test_failed_execution(mut_output, push_changes):
    with pytest.raises(Exception):
        run_task(
            mut_output=mut_output,
            task_def_arn=mut_output["ecs_pr_plan_task_definition_arn"],
            task_env_vars={
                "REPO_FULL_NAME": mut_output["repo_full_name"],
                "STATUS_CHECK_NAME": mut_output["pr_plan_status_check_name"],
                "CFG_PATH": push_changes["branch"],
                "COMMIT_ID": push_changes["commit_id"],
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
