import os
import logging
import fnmatch
import json
from pprint import pformat
import sys

import boto3
import github

sys.path.append(os.path.dirname(__file__))
from utils import aws_encode, ServerException, get_logger  # noqa E402

log = get_logger()
log.setLevel(logging.DEBUG)

ssm = boto3.client("ssm", endpoint_url=os.environ.get("SSM_ENDPOINT_URL"))
ecs = boto3.client("ecs", endpoint_url=os.environ.get("ECS_ENDPOINT_URL"))


def merge_lock(repo_full_name, head_ref, logs_url):
    """Creates a PR commit status that shows the current merge lock status"""

    merge_lock = ssm.get_parameter(Name=os.environ["MERGE_LOCK_SSM_KEY"])["Parameter"][
        "Value"
    ]
    log.info(f"Merge lock value: {merge_lock}")
    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])

    head = gh.get_repo(repo_full_name).get_branch(head_ref)

    if merge_lock != "none":
        log.info("Merge lock status: locked")
        head.commit.create_status(
            state="pending",
            description=f"Locked -- In Progress PR #{merge_lock}",
            context=os.environ["MERGE_LOCK_STATUS_CHECK_NAME"],
            target_url=logs_url,
        )

    elif merge_lock == "none":
        log.info("Merge lock status: unlocked")
        head.commit.create_status(
            state="success",
            description="Unlocked",
            context=os.environ["MERGE_LOCK_STATUS_CHECK_NAME"],
            target_url=logs_url,
        )

    else:
        raise ServerException(f"Invalid merge lock value: {merge_lock}")


def trigger_pr_plan(
    repo_full_name: str,
    base_ref: str,
    head_ref: str,
    head_sha: str,
    logs_url: str,
    send_commit_status: bool,
) -> None:
    """
    Runs the PR Terragrunt plan ECS task for every added or modified Terragrunt
    directory

    Arguments:
        send_commit_status: Send a pending commit status for each of the
            PR plan ECS task
    """

    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])

    log.info("Getting diff files")
    diff_paths = list(
        set(
            [
                f.filename
                for f in gh.get_repo(repo_full_name).compare(base_ref, head_ref).files
                if f.status in ["added", "modified"]
            ]
        )
    )
    log.debug(f"Added or modified files within PR:\n{pformat(diff_paths)}")

    for account in json.loads(os.environ["ACCOUNT_DIM"]):
        log.debug(f"Account Record:\n{account}")

        account_diff_paths = list(
            set(
                [
                    os.path.dirname(filename)
                    for filename in diff_paths
                    if fnmatch.fnmatch(filename, f'{account["path"]}/**.hcl')
                    or fnmatch.fnmatch(filename, f'{account["path"]}/**.tf')
                ]
            )
        )

        if len(account_diff_paths) > 0:
            log.debug(
                f"Account-level Terragrunt/Terraform diff files:\n{account_diff_paths}"
            )
            log.info(f"Count: {len(account_diff_paths)}")
            log.info(f'Plan Role ARN: {account["plan_role_arn"]}')

            log_options = ecs.describe_task_definition(
                taskDefinition=os.environ["PR_PLAN_TASK_DEFINITION_ARN"]
            )["taskDefinition"]["containerDefinitions"][0]["logConfiguration"][
                "options"
            ]

            log.info("Running ECS tasks")
            for path in account_diff_paths:
                log.info(f"Directory: {path}")
                status_check_name = f"Plan: {path}"
                try:
                    task = ecs.run_task(
                        cluster=os.environ["ECS_CLUSTER_ARN"],
                        count=1,
                        launchType="FARGATE",
                        taskDefinition=os.environ["PR_PLAN_TASK_DEFINITION_ARN"],
                        networkConfiguration=json.loads(
                            os.environ["ECS_NETWORK_CONFIG"]
                        ),
                        startedBy=head_sha,
                        overrides={
                            "containerOverrides": [
                                {
                                    "name": os.environ["PR_PLAN_TASK_CONTAINER_NAME"],
                                    "command": [
                                        "python",
                                        "/src/pr_plan/plan.py",
                                    ],
                                    "environment": [
                                        {
                                            "name": "SOURCE_VERSION",
                                            "value": head_ref,
                                        },
                                        {
                                            "name": "COMMIT_ID",
                                            "value": head_sha,
                                        },
                                        {"name": "CFG_PATH", "value": path},
                                        {
                                            "name": "ROLE_ARN",
                                            "value": account["plan_role_arn"],
                                        },
                                        {
                                            "name": "STATUS_CHECK_NAME",
                                            "value": status_check_name,
                                        },
                                    ],
                                }
                            ]
                        },
                    )
                    log.debug(f"Run task response:\n{pformat(task)}")

                    task_id = task["tasks"][0]["taskArn"].split("/")[-1]
                    status_data = {
                        "state": "pending",
                        "description": "Terraform Plan",
                        "context": status_check_name,
                        "target_url": f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(log_options["awslogs-group"])}/log-events/{aws_encode(log_options["awslogs-stream-prefix"] + "/" + os.environ["PR_PLAN_TASK_CONTAINER_NAME"] + "/" + task_id)}',
                    }
                except Exception as e:
                    log.error(e, exc_info=True)
                    status_data = {
                        "state": "failure",
                        "description": "Terraform Plan",
                        "context": status_check_name,
                        "target_url": logs_url,
                    }

                log.info("Sending commit status for Terraform plan")
                log.debug(f"Status data:\n{pformat(status_data)}")
                if send_commit_status:
                    head = gh.get_repo(repo_full_name).get_branch(head_ref)
                    log.debug(head.commit.create_status(**status_data))
        else:
            log.info(
                "No New/Modified Terragrunt/Terraform configurations within account -- skipping plan"
            )


def trigger_create_deploy_stack(
    repo_full_name,
    base_ref,
    head_ref,
    head_sha,
    pr_id,
    logs_url,
    send_commit_status,
) -> None:
    """
    Runs the Create Deploy Stack ECS task

    Arguments:
        pr_id: PR ID or also referred to as PR number
        send_commit_status: Send a pending commit status for each of the PR plan ECS task
    """

    log_options = ecs.describe_task_definition(
        taskDefinition=os.environ["CREATE_DEPLOY_STACK_TASK_DEFINITION_ARN"]
    )["taskDefinition"]["containerDefinitions"][0]["logConfiguration"]["options"]

    try:
        task = ecs.run_task(
            cluster=os.environ["ECS_CLUSTER_ARN"],
            count=1,
            launchType="FARGATE",
            taskDefinition=os.environ["CREATE_DEPLOY_STACK_TASK_DEFINITION_ARN"],
            networkConfiguration=json.loads(os.environ["ECS_NETWORK_CONFIG"]),
            startedBy=head_sha,
            overrides={
                "containerOverrides": [
                    {
                        "name": os.environ["CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME"],
                        "environment": [
                            {"name": "BASE_REF", "value": base_ref},
                            {"name": "HEAD_REF", "value": head_ref},
                            {"name": "PR_ID", "value": str(pr_id)},
                            {"name": "COMMIT_ID", "value": head_sha},
                        ],
                    }
                ]
            },
        )
        log.debug(f"Run task response:\n{pformat(task)}")

        task_id = task["tasks"][0]["taskArn"].split("/")[-1]
        status_data = {
            "state": "pending",
            "description": "Create Deploy Stack",
            "context": os.environ["CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT"],
            "target_url": f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(log_options["awslogs-group"])}/log-events/{aws_encode(log_options["awslogs-stream-prefix"] + "/" + os.environ["CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME"] + "/" + task_id)}',
        }
    except Exception as e:
        log.error(e, exc_info=True)
        status_data = {
            "state": "failure",
            "description": "Create Deploy Stack",
            "context": os.environ["CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT"],
            "target_url": logs_url,
        }
    if send_commit_status:
        log.info("Sending commit status")
        log.debug(f"Status data:\n{pformat(status_data)}")
        gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])
        head = gh.get_repo(repo_full_name).get_branch(head_ref)
        head.commit.create_status(**status_data)
