import boto3
import logging
import json
import os
import github
import urllib
import re
import fnmatch
from pprint import pformat

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

ssm = boto3.client("ssm")
ecs = boto3.client("ecs")


class ServerException(Exception):
    pass


def aws_encode(value):
    """Encodes value into AWS friendly URL component"""
    value = urllib.parse.quote_plus(value)
    value = re.sub(r"\+", " ", value)
    return re.sub(r"%", "$", urllib.parse.quote_plus(value))


class Invoker:
    def __init__(self, token, repo_full_name, base_ref, head_ref, logs_url):
        """


        Arguments:
            base_ref: PR base ref
            head_ref: PR head ref
            logs_url: Cloudwatch log group stream associated with AWS Lambda
                Function invocation
        """
        self.repo_full_name = repo_full_name
        self.base_ref = base_ref
        self.head_ref = head_ref
        self.logs_url = logs_url

        self.gh = github.Github(token)
        self.repo = self.gh.get_repo(self.repo_full_name)
        self.base = self.repo.get_branch(self.base_ref)
        self.head = self.repo.get_branch(self.head_ref)

    def merge_lock(self):
        """Creates a PR commit status that shows the current merge lock status"""
        merge_lock = ssm.get_parameter(Name=os.environ["MERGE_LOCK_SSM_KEY"])[
            "Parameter"
        ]["Value"]
        log.info(f"Merge lock value: {merge_lock}")

        if merge_lock != "none":
            log.info("Merge lock status: locked")
            self.head.commit.create_status(
                state="pending",
                description=f"Locked -- In Progress PR #{merge_lock}",
                context=os.environ["MERGE_LOCK_STATUS_CHECK_NAME"],
                target_url=self.logs_url,
            )

        elif merge_lock == "none":
            log.info("Merge lock status: unlocked")
            self.head.commit.create_status(
                state="success",
                description="Unlocked",
                context=os.environ["MERGE_LOCK_STATUS_CHECK_NAME"],
                target_url=self.logs_url,
            )

        else:
            raise ServerException(f"Invalid merge lock value: {merge_lock}")

    def trigger_pr_plan(self, send_commit_status) -> None:
        """
        Runs the PR Terragrunt plan ECS task for every added or modified Terragrunt
        directory

        Arguments:
            send_commit_status: Send a pending commit status for each of the PR plan ECS task
        """

        log.info("Getting diff files")
        diff_paths = list(
            set(
                [
                    f.filename
                    for f in self.repo.compare(self.base_ref, self.head_ref).files
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
                                        "name": os.environ[
                                            "PR_PLAN_TASK_CONTAINER_NAME"
                                        ],
                                        "command": [
                                            "python",
                                            "/src/pr_plan/plan.py",
                                        ],
                                        "environment": [
                                            {
                                                "name": "SOURCE_VERSION",
                                                "value": self.head_ref,
                                            },
                                            {
                                                "name": "COMMIT_ID",
                                                "value": self.head.commit.sha,
                                            },
                                            {"name": "CFG_PATH", "value": path},
                                            {
                                                "name": "ROLE_ARN",
                                                "value": account["plan_role_arn"],
                                            },
                                            {"name": "CONTEXT", "value": context},
                                        ],
                                    }
                                ]
                            },
                        )
                        log.debug(f"Run task response:\n{pformat(task)}")

                        task_id = task["tasks"][0]["containers"][0]["taskArn"].split(
                            "/"
                        )[-1]
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
                            "target_url": self.logs_url,
                        }

                    log.info("Sending commit status for Terraform plan")
                    log.debug(f"Status data:\n{pformat(status_data)}")
                    if send_commit_status:
                        self.head.commit.create_status(**status_data)
            else:
                log.info(
                    "No New/Modified Terragrunt/Terraform configurations within account -- skipping plan"
                )

    def trigger_create_deploy_stack(
        self,
        pr_id,
        send_commit_status: bool,
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
                overrides={
                    "containerOverrides": [
                        {
                            "name": os.environ[
                                "CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME"
                            ],
                            "environment": [
                                {"name": "BASE_REF", "value": self.base_ref},
                                {"name": "HEAD_REF", "value": self.head_ref},
                                {"name": "PR_ID", "value": pr_id},
                                {"name": "COMMIT_ID", "value": self.head.commit.sha},
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
                "target_url": f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(log_options["awslogs-group"])}/log-events/{aws_encode(log_options["awslogs-stream-prefix"] + "/" + os.environ["CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME"] + "/" + task_id)}',
            }
        except Exception as e:
            log.error(e, exc_info=True)
            status_data = {
                "state": "failure",
                "description": "Create Deploy Stack",
                "context": os.environ["CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT"],
                "target_url": self.logs_url,
            }
        if send_commit_status:
            log.info("Sending commit status")
            log.debug(f"Status data:\n{pformat(status_data)}")
            self.head.commit.create_status(**status_data)


def lambda_handler(event, context):
    """
    Runs the approriate workflow depending upon on if the function was triggered
    by an open PR activity or PR merge event
    """

    log.debug(f"Event:\n{pformat(event)}")
    payload = json.loads(event["body"])

    token = ssm.get_parameter(
        Name=os.environ["GITHUB_TOKEN_SSM_KEY"], WithDecryption=True
    )["Parameter"]["Value"]

    invoker = Invoker(
        token,
        payload["repository"]["full_name"],
        payload["pull_request"]["base"]["ref"],
        payload["pull_request"]["head"]["ref"],
        f'https://{os.environ["AWS_REGION"]}.console.aws.amazon.com/cloudwatch/home?region={os.environ["AWS_REGION"]}#logsV2:log-groups/log-group/{aws_encode(context.log_group_name)}/log-events/{aws_encode(context.log_stream_name)}',
    )

    commit_status_config = json.loads(
        ssm.get_parameter(Name=os.environ["COMMIT_STATUS_CONFIG_SSM_KEY"])["Parameter"][
            "Value"
        ]
    )
    log.debug(f"Commit status config:\n{pformat(commit_status_config)}")

    if not payload["pull_request"]["merged"]:
        log.info("Running workflow for open PR")

        invoker.merge_lock()
        invoker.trigger_pr_plan(commit_status_config["PrPlan"])
    else:
        log.info("Running workflow for merged PR")
        invoker.trigger_create_deploy_stack(
            str(payload["pull_request"]["number"]),
            commit_status_config["CreateDeployStack"],
        )
