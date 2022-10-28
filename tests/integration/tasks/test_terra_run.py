import os
import uuid
import logging

import pytest
import boto3
import github
import timeout_decorator

from tests.helpers.utils import (
    dummy_tf_output,
    wait_for_finished_task,
    get_commit_status,
)

log = logging.getLogger(__file__)
log.setLevel(logging.DEBUG)
gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])


# need support in order to pass custom endpoint URL for terragrunt command with
# --terragrunt-iam-role flag
# @pytest.mark.skip("Waiting on Terragrunt Issue: #2282")
@timeout_decorator.timeout(60)
@pytest.mark.usefixtures("truncate_executions")
@pytest.mark.parametrize(
    "push_changes",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output()
            },
        ),
    ],
    indirect=True,
)
def test_successful_apply_task(mut_output, push_changes):
    ecs = boto3.client("ecs", endpoint_url=mut_output.get("ecs_endpoint_url"))

    cfg_path = os.path.dirname(list(push_changes["changes"].keys())[0])
    status_check_name = f"test-{uuid.uuid4()}"

    task_arn = ecs.run_task(
        taskDefinition=mut_output["ecs_terra_run_task_definition_arn"],
        overrides={
            "containerOverrides": [
                {
                    "name": mut_output["ecs_terra_run_task_container_name"],
                    "environment": [
                        {"name": "STATE_NAME", "value": "Apply"},
                        {"name": "AWS_DEFAULT_REGION", "value": "us-west-2"},
                        {"name": "CFG_PATH", "value": cfg_path},
                        {
                            "name": "COMMIT_ID",
                            "value": push_changes["commit_id"],
                        },
                        {
                            "name": "ROLE_ARN",
                            "value": mut_output["ecs_apply_role_arn"],
                        },
                        {
                            "name": "EXECUTION_ID",
                            "value": "run-123",
                        },
                        {
                            "name": "TG_COMMAND",
                            "value": f"terragrunt apply --terragrunt-working-dir {cfg_path} --terragrunt-iam-role {mut_output['apply_role_arn']} -auto-approve",
                        },
                        {
                            "name": "TASK_TOKEN",
                            "value": "task-token-123",
                        },
                        {"name": "STATUS_CHECK_NAME", "value": status_check_name},
                    ],
                }
            ]
        },
    )
    task_arn = task_arn["tasks"][0]["taskArn"]

    wait_for_finished_task(
        mut_output["ecs_cluster_arn"], task_arn, mut_output.get("ecs_endpoint_url")
    )

    status = get_commit_status(
        mut_output["repo_full_name"], push_changes["commit_id"], status_check_name
    )

    log.info("Assert that expected commit status state is sent")
    assert status == "success"


@pytest.mark.skip("not implemented")
def test_failed_apply_task():
    pass
    # create case where apply_role_arn does not have the proper IAM permissions to run apply
    # and terraform creates the new provider resources but fails to create other downstream resources
    # TODO: assert new provider resources that were written to tf state file were added to metadb record's
    # new_resources column

    # TODO: assert commit status == failure
