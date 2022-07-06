import boto3
import logging
import json
import os
import requests
import sys
import urllib
import re
import fnmatch
from pprint import pformat

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

ssm = boto3.client("ssm")
ecs = boto3.client("ecs")


def aws_encode(value):
    """Encodes value into AWS friendly URL component"""
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


def merge_lock(headers, commit_url, target_url):
    """Creates a PR commit status that shows the current merge lock status"""
    merge_lock = ssm.get_parameter(Name=os.environ["MERGE_LOCK_SSM_KEY"])["Parameter"][
        "Value"
    ]
    log.info(f"Merge lock value: {merge_lock}")

    if merge_lock != "none":
        log.info("Merge lock status: locked")
        data = {
            "state": "pending",
            "description": f"Locked -- In Progress PR #{merge_lock}",
            "context": os.environ["MERGE_LOCK_STATUS_CHECK_NAME"],
            "target_url": target_url,
        }
    elif merge_lock == "none":
        log.info("Merge lock status: unlocked")
        data = {
            "state": "success",
            "description": "Unlocked",
            "context": os.environ["MERGE_LOCK_STATUS_CHECK_NAME"],
            "target_url": target_url,
        }

    else:
        log.error(f"Invalid merge lock value: {merge_lock}")
        sys.exit(1)

    log.debug(f"Response Data:\n{data}")

    log.info("Sending response")
    response = requests.post(commit_url, headers=headers, json=data)
    log.debug(f"Response:\n{response}")


def trigger_pr_plan(
    headers: dict,
    commit_url: str,
    commit_statuses_url: str,
    compare_url: str,
    branch_protection_url: str,
    lambda_logs_url: str,
    head_ref: str,
    commit_id: str,
    send_commit_status: bool,
) -> None:
    """
    Runs the PR Terragrunt plan ECS task for every added or modified Terragrunt
    directory

    Arguments:
        headers: GitHub authorization headers
        commit_url: GitHub API commit URL
        commit_statuses_url: GitHub API commit statuses URL
        compare_url: GitHub API compare URL interpolated with PR base and head refs
        branch_protection_url: GitHub API branch protection URL for the base ref
        lambda_logs_url: Cloudwatch log group stream associated with function invocation
        head_ref: PR head ref
        commit_id: PR head ref commit ID
        send_commit_status: Send a pending commit status for each of the PR plan ECS task
    """

    log.info("Getting diff files")
    log.debug(f"Compare URL: {compare_url}")
    compare_payload = requests.get(compare_url, headers=headers).json()

    log.debug(f"Compare URL Payload:\n{pformat(compare_payload)}")

    diff_paths = list(
        set(
            [
                f["filename"]
                for f in compare_payload["files"]
                if f["status"] in ["added", "modified"]
            ]
        )
    )

    log.debug(f"Added or modified files within PR:\n{pformat(diff_paths)}")

    plan_contexts = []
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
                context = f"Plan: {path}"
                try:
                    task = ecs.run_task(
                        cluster=os.environ["ECS_CLUSTER_ARN"],
                        count=1,
                        launchType="FARGATE",
                        taskDefinition=os.environ["PR_PLAN_TASK_DEFINITION_ARN"],
                        networkConfiguration=json.loads(
                            os.environ["ECS_NETWORK_CONFIG"]
                        ),
                        overrides={
                            "containerOverrides": [
                                {
                                    "name": os.environ["PR_PLAN_TASK_CONTAINER_NAME"],
                                    "command": [
                                        "python",
                                        "/src/pr_plan/plan.py",
                                    ],
                                    "environment": [
                                        {"name": "SOURCE_VERSION", "value": head_ref},
                                        {"name": "COMMIT_ID", "value": commit_id},
                                        {"name": "CFG_PATH", "value": path},
                                        {
                                            "name": "ROLE_ARN",
                                            "value": account["plan_role_arn"],
                                        },
                                        {"name": "CONTEXT", "value": context},
                                        {
                                            "name": "COMMIT_STATUSES_URL",
                                            "value": commit_statuses_url,
                                        },
                                    ],
                                }
                            ]
                        },
                    )
                    log.debug(f"Run task response:\n{pformat(task)}")

                    task_id = task["tasks"][0]["containers"][0]["taskArn"].split("/")[
                        -1
                    ]
                    status_data = {
                        "state": "pending",
                        "description": "Terraform Plan",
                        "context": context,
                        "target_url": f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(log_options["awslogs-group"])}/log-events/{aws_encode(log_options["awslogs-stream-prefix"] + "/" + os.environ["PR_PLAN_TASK_CONTAINER_NAME"] + "/" + task_id)}',
                    }
                except Exception as e:
                    log.error(e, exc_info=True)
                    status_data = {
                        "state": "failure",
                        "description": "Terraform Plan",
                        "context": context,
                        "target_url": lambda_logs_url,
                    }

                log.info("Sending commit status for Terraform plan")
                log.debug(f"Status data:\n{pformat(status_data)}")
                if send_commit_status:
                    response = requests.post(
                        commit_url,
                        headers=headers,
                        json=status_data,
                    )
                    log.debug(f"Response:\n{response.text}")

                    plan_contexts.append(context)

            if send_commit_status:
                log.info(
                    "Adding directory plans to branch protection required status checks"
                )
                log.debug(f"Branch protection URL: {branch_protection_url}")
                protection_data = requests.get(
                    branch_protection_url, headers=headers
                ).json()
                log.debug(f"Branch protection payload: {pformat(protection_data)}")

                log.info("Adding Terraform plan(s) to required status checks")
                protection_data["required_status_checks"]["contexts"] += plan_contexts
                requests.put(
                    branch_protection_url, headers=headers, data=protection_data
                )
        else:
            log.info(
                "No New/Modified Terragrunt/Terraform configurations within account -- skipping plan"
            )


def trigger_create_deploy_stack(
    headers: str,
    base_ref: str,
    head_ref: str,
    pr_id: str,
    commit_id: str,
    commit_url: str,
    lambda_logs_url: str,
    send_commit_status: bool,
) -> None:
    """
    Runs the Create Deploy Stack ECS task

    Arguments:
        headers: GitHub authorization headers
        base_ref: PR base ref
        head_ref: PR head ref
        pr_id: PR ID or also referred to as PR number
        commit_id: PR head ref commit ID
        commit_url: GitHub API commit URL
        lambda_logs_url: Cloudwatch log group stream associated with function invocation
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
            overrides={
                "containerOverrides": [
                    {
                        "name": os.environ["CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME"],
                        "environment": [
                            {"name": "BASE_REF", "value": base_ref},
                            {"name": "HEAD_REF", "value": head_ref},
                            {"name": "PR_ID", "value": pr_id},
                            {"name": "COMMIT_ID", "value": commit_id},
                        ],
                    }
                ]
            },
        )
        log.debug(f"Run task response:\n{pformat(task)}")

        task_id = task["tasks"][0]["containers"][0]["taskArn"].split("/")[-1]
        status_data = {
            "state": "pending",
            "description": "Create Deploy Stack",
            "context": os.environ["CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT"],
            "target_url": f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(log_options["awslogs-group"])}/log-events/{aws_encode(log_options["awslogs-stream-prefix"] + "/" + os.environ["PR_PLAN_TASK_CONTAINER_NAME"] + "/" + task_id)}',
        }
    except Exception as e:
        log.error(e, exc_info=True)
        status_data = {
            "state": "failure",
            "description": "Create Deploy Stack",
            "context": os.environ["CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT"],
            "target_url": lambda_logs_url,
        }
    if send_commit_status:
        log.info("Sending commit status")
        log.debug(f"Status data:\n{pformat(status_data)}")

        requests.post(
            commit_url,
            headers=headers,
            json=status_data,
        )


def lambda_handler(event, context):
    """
    Runs the approriate workflow depending upon on if the function was triggered
    by an open PR activity or PR merge event
    """

    log.debug(f"Event:\n{pformat(event)}")

    payload = json.loads(event["requestPayload"]["body"])

    token = ssm.get_parameter(
        Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    commit_status_config = json.loads(
        ssm.get_parameter(Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"])["Parameter"][
            "Value"
        ]
    )

    log.debug(f"Commit status config:\n{pformat(commit_status_config)}")

    repo_full_name = payload["repository"]["full_name"]
    pr_id = payload["pull_request"]["number"]
    commit_id = payload["pull_request"]["head"]["sha"]
    head_ref = payload["pull_request"]["head"]["ref"]

    log.info(f"Repo: {repo_full_name}")
    log.info(f"Commit ID: {commit_id}")
    log.info(f"PR ID: {pr_id}")

    commit_url = f"https://api.github.com/repos/{repo_full_name}/statuses/{commit_id}"  # noqa: E501

    headers = {
        "Accept": "application/vnd.github.v3+json",
        "Authorization": f"token {token}",
    }
    logs_url = f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(context.log_group_name)}/log-events/{aws_encode(context.log_stream_name)}'

    if not payload["pull_request"]["merged"]:
        log.info("Running workflow for open PR")

        merge_lock(headers, commit_url, logs_url)

        trigger_pr_plan(
            headers,
            commit_url,
            f"https://api.github.com/repos/{repo_full_name}/commits/{commit_id}/statuses",
            payload["repository"]["compare_url"].format(
                base=payload["pull_request"]["base"]["sha"],
                head=payload["pull_request"]["head"]["sha"],
            ),
            f"{payload['pull_request']['base']['repo']['branches_url'].replace('{/branch}', '/' + payload['pull_request']['base']['ref'])}/protection",
            logs_url,
            head_ref,
            commit_id,
            commit_status_config["PrPlan"],
        )
    else:
        log.info("Running workflow for merged PR")
        trigger_create_deploy_stack(
            headers,
            payload["pull_request"]["base"]["ref"],
            head_ref,
            str(pr_id),
            commit_id,
            commit_url,
            logs_url,
            commit_status_config["CreateDeployStack"],
        )
