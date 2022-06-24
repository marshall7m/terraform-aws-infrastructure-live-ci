import boto3
import logging
import json
import os
import sys
import requests
from pprint import pformat
import urllib
import fnmatch
import re

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

ecs = boto3.client("ecs")
ssm = boto3.client("ssm")


def aws_encode(value):
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


def lambda_handler(event, context):

    log.debug(f"Event:\n{pformat(event)}")

    payload = json.loads(event["requestPayload"]["body"])

    token = ssm.get_parameter(
        Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    headers = {
        "Accept": "application/vnd.github.v3+json",
        "Authorization": f"token {token}",
    }

    commit_id = payload["pull_request"]["head"]["sha"]
    repo_full_name = payload["repository"]["full_name"]
    log.info(f"Commit ID: {commit_id}")
    log.info(f"Repo: {repo_full_name}")

    commit_url = f"https://api.github.com/repos/{repo_full_name}/statuses/{commit_id}"  # noqa: E501
    # TODO: Replace with each direcotories associated ecs task cw log stream
    target_url = f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(context["log_group_name"])}/log-events/{aws_encode(context["log_stream_name"])}'  # noqa: E501

    log.info("Getting diff files")
    log.debug(f"Compare URL: {payload['compare_url']}")
    compare_payload = requests.get(payload["compare_url"], headers=headers).json()

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

            log.info("Running ECS tasks")
            for path in account_diff_paths:
                log.info(f"Directory: {path}")
                try:
                    ecs.run_task(
                        cluster=os.environ["ECS_CLUSTER_ARN"],
                        count=1,
                        launchType="FARGATE",
                        taskDefinition=os.environ["ECS_TASK_DEFINITION_ARN"],
                        overrides={
                            "containerOverrides": [
                                {
                                    "name": path,
                                    "command": "python ci-repo/ecs/pr_plan/plan.py",
                                    "environment": [
                                        {
                                            "name": "GITHUB_TOKEN_SSM_KEY",
                                            "value": os.environ["GITHUB_TOKEN_SSM_KEY"],
                                        },
                                        {"name": "COMMIT_ID", "value": commit_id},
                                        {
                                            "name": "REPO_FULL_NAME",
                                            "value": repo_full_name,
                                        },
                                        {
                                            "name": "AWS_REGION",
                                            "value": os.environ["AWS_REGION"],
                                        },
                                        {"name": "CFG_PATH", "value": path},
                                        {
                                            "name": "ROLE_ARN",
                                            "value": account["plan_role_arn"],
                                        },
                                    ],
                                }
                            ]
                        },
                    )
                    state = "pending"
                except Exception as e:
                    log.error(e, exc_info=True)
                    state = "failure"

                log.info("Sending commit status")
                context = f"Plan: {path}"
                response = requests.post(
                    commit_url,
                    json={
                        "state": state,
                        "description": "Terraform Plan",
                        "context": context,
                        "target_url": target_url,
                    },
                )
                log.debug(f"Response:\n{response}")

                plan_contexts.append(context)

            log.info(
                "Adding directory plans to branch protection required status checks"
            )
            protection_url = f"https://api.github.com/repos/{repo_full_name}/branches/{os.environ['BASE_BRANCH']}/protection"
            protection_data = requests.get(protection_url, headers=headers).json()

            protection_data["required_status_checks"] += plan_contexts
            requests.put(protection_url, headers=headers, data=protection_data)

        else:
            log.info(
                "No New/Modified Terragrunt/Terraform configurations within account -- skipping plan"
            )
