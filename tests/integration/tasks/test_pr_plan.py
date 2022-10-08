import logging
import uuid
import os

import pytest
import github
import boto3

from tests.helpers.utils import dummy_tf_output

log = logging.getLogger(__file__)
log.setLevel(logging.DEBUG)
gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])


@pytest.mark.usefixtures("reset_moto_server")
@pytest.mark.parametrize(
    "push_changes, expected_status",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output()
            },
            "success",
            id="valid_tf_file",
        ),
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output(
                    name="1_invalid_name"
                )
            },
            "failure",
            id="invalid_tf_file",
        ),
    ],
    indirect=["push_changes"],
)
def test_successful_execution(mut_output, push_changes, expected_status):
    ecs = boto3.client("ecs", endpoint_url=mut_output.get("ecs_endpoint_url"))

    cfg_path = os.path.dirname(list(push_changes["changes"].keys())[0])
    ecs.run_task(
        taskDefinition=mut_output["ecs_pr_plan_task_definition_arn"],
        overrides={
            "containerOverrides": [
                {
                    "name": mut_output["ecs_pr_plan_container_name"],
                    "environment": [
                        {"name": "CFG_PATH", "value": cfg_path},
                        {
                            "name": "COMMIT_ID",
                            "value": push_changes["commit_id"],
                        },
                    ],
                }
            ]
        },
    )

    repo = gh.get_repo(mut_output["repo_full_name"])
    status = [
        status
        for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
        if status.context == mut_output["pr_plan_status_check_name"]
    ][0]

    log.info("Assert that expected commit status state is sent")
    assert status.state == expected_status
