import os
import uuid
import logging
import json

import pytest
import boto3
import github
import aurora_data_api
from tests.helpers.utils import dummy_tf_output

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)
rds_data = boto3.client("rds-data", endpoint_url=os.environ["METADB_ENDPOINT_URL"])


def get_commit_cfg_paths(commit_id, mut_output):
    with aurora_data_api.connect(
        aurora_cluster_arn=mut_output["metadb_arn"],
        secret_arn=mut_output["metadb_secret_manager_master_arn"],
        database=mut_output["metadb_name"],
        rds_data_client=rds_data,
    ) as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"""
            SELECT array_agg(cfg_path::TEXT)
            FROM {mut_output["metadb_schema"]}.executions
            WHERE commit_id = '{commit_id}'
            """
            )
            results = cur.fetchone()[0]

    return [] if results is None else [id for id in results]


@pytest.fixture
def send_commit_status(push_changes, mut_output):
    commit = (
        github.Github(os.environ["GITHUB_TOKEN"], retry=3)
        .get_repo(mut_output["repo_full_name"])
        .get_commit(push_changes["commit_id"])
    )

    log.info("Sending commit status")
    commit.create_status(
        state="pending",
        context=mut_output["create_deploy_stack_status_check_name"],
        target_url="http://localhost:8080",
    )


@pytest.fixture(scope="class")
def remove_iam_role(mut_output):
    """Removes assumable IAM role from service"""
    iam = boto3.client("iam")
    iam_res = boto3.resource("iam")

    log.info("Creating deny policy")
    response = iam.create_policy(
        PolicyName=f'{mut_output["ecs_create_deploy_stack_family"]}-test-error',
        PolicyDocument=json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Deny",
                        "Action": "sts:AssumeRole",
                        "Resource": mut_output["plan_role_arn"],
                    }
                ],
            }
        ),
        Description="Overwrites the services ability to assume the specified role",
    )

    arn = response["Policy"]["Arn"]
    role = iam_res.Role(mut_output["ecs_create_deploy_stack_family"])

    log.debug(
        f'Attaching policy to role: {mut_output["ecs_create_deploy_stack_family"]}'
    )
    role.attach_policy(PolicyArn=arn)

    yield arn

    log.info("Detaching Deny policy")
    response = role.detach_policy(PolicyArn=arn)

    log.info("Deleting Deny policy")
    response = iam.delete_policy(PolicyArn=arn)


@pytest.fixture
def run_task(mut_output, push_changes):
    ecs = boto3.client("ecs", endpoint_url=mut_output.get("ecs_endpoint_url"))

    res = ecs.run_task(
        taskDefinition=mut_output["ecs_create_deploy_stack_definition_arn"],
        overrides={
            "containerOverrides": [
                {
                    "name": mut_output["ecs_create_deploy_stack_container_name"],
                    "environment": [
                        {
                            "name": "BASE_REF",
                            "value": push_changes["branch"],
                        },
                        {
                            "name": "HEAD_REF",
                            "value": "feature-123",
                        },
                        {
                            "name": "PR_ID",
                            "value": "1",
                        },
                        {
                            "name": "COMMIT_ID",
                            "value": push_changes["commit_id"],
                        },
                    ],
                }
            ]
        },
    )

    yield res

    if not os.environ.get("IS_REMOTE"):
        log.debug("Removing local ecs task")
    #     # if any test(s) failed, keep container to access docker logs for debugging
    #     if not getattr(request.node.obj, "any_failures", False):
    #         docker.container.remove(container, force=True)


@pytest.mark.usefixtures("truncate_executions", "send_commit_status")
@pytest.mark.parametrize(
    "push_changes,expected_cfg_paths",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output()
            },
            ["directory_dependency/shared-services-account/us-west-2/env-one/doo"],
            id="one_node",
        )
    ],
    indirect=["push_changes"],
)
def test_successful_execution(expected_cfg_paths, mut_output, push_changes, run_task):
    """
    Test ensures that the proper IAM permissions for the task role are in place, execution runs
    without any failures, expected metadb execution records were created, and expected commit status is sent.
    """

    actual_cfg_paths = get_commit_cfg_paths(push_changes["commit_id"], mut_output)

    log.info("Assert that all expected cfg_paths are within executions table")
    assert len(expected_cfg_paths) == len(actual_cfg_paths) and sorted(
        expected_cfg_paths
    ) == sorted(actual_cfg_paths)

    repo = gh.get_repo(mut_output["repo_full_name"])
    status = [
        status
        for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
        if status.context == mut_output["create_deploy_stack_status_check_name"]
    ][0]

    log.info("Assert that expected commit status state is sent")
    assert status.state == "success"


@pytest.mark.usefixtures("truncate_executions", "send_commit_status", "remove_iam_role")
@pytest.mark.parametrize(
    "push_changes",
    [
        pytest.param(
            {
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output(),
                f"directory_dependency/shared-services-account/us-west-2/env-one/doo/{uuid.uuid4()}.tf": dummy_tf_output(),
            }
        )
    ],
    indirect=True,
)
def test_failed_execution(mut_output, push_changes, run_task):
    """
    Case covers a simple 2 node deployment with one node having an account-level dependency on the other.
    See the account_dim table to see the account dependency testing layout.
    The error caused by the invalid Terraform configuration(s) within the dev-account should cause the create_deploy_stack.py script to
    rollback the shared-services account's execution records and fail the build entirely without any other downstream services being invoked.
    """

    actual_cfg_paths = get_commit_cfg_paths(push_changes["commit_id"], mut_output)

    log.info(
        "Assert that are no records within the execution table from the testing commit ID"
    )
    assert len(actual_cfg_paths) == 0

    repo = gh.get_repo(mut_output["repo_full_name"])
    status = [
        status
        for status in repo.get_commit(push_changes["commit_id"]).get_statuses()
        if status.context == mut_output["create_deploy_stack_status_check_name"]
    ][0]

    log.info("Assert that expected commit status state is sent")
    assert status.state == "failure"
