import logging
import uuid
import os

import pytest
import boto3
import timeout_decorator

from tests.helpers.utils import (
    dummy_tf_output,
    wait_for_finished_task,
    get_commit_status,
)

log = logging.getLogger(__file__)
log.setLevel(logging.DEBUG)


# need support in order to pass custom endpoint URL for terragrunt command with
# --terragrunt-iam-role flag
@pytest.mark.skip("Waiting on Terragrunt Issue: #2282")
@timeout_decorator.timeout(60)
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
    task_arn = ecs.run_task(
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
                        {
                            "name": "SOURCE_VERSION",
                            "value": push_changes["branch"],
                        },
                        {
                            "name": "ROLE_ARN",
                            "value": mut_output["plan_role_arn"],
                        },
                        {
                            "name": "STATUS_CHECK_NAME",
                            "value": cfg_path,
                        },
                    ],
                }
            ]
        },
    )["tasks"][0]["taskArn"]

    wait_for_finished_task(
        mut_output["ecs_cluster_arn"], task_arn, mut_output.get("ecs_endpoint_url")
    )

    status = get_commit_status(
        mut_output["repo_full_name"], push_changes["commit_id"], cfg_path
    )

    log.info("Assert that expected commit status state is sent")
    assert status == expected_status
