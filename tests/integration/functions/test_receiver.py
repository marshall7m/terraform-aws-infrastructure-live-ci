import os
import logging
import json
import hmac
import hashlib
import uuid
import requests

import pytest
import boto3
from python_on_whales import docker

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

base_event = {
    "body": {
        "repository": {"full_name": "test-repo"},
        "pull_request": {
            "number": 1,
            "base": {"sha": "base-sha", "ref": "master"},
            "head": {"sha": "head-sha", "ref": "head"},
        },
    },
    "headers": {
        "content-type": "application/json",
        "x-github-event": "pull_request",
        "x-hub-signature-256": "sha256=12321",
    },
    "isBase64Encoded": False,
    "queryStringParameters": {"parameter1": "value1,value2", "parameter2": "value"},
    "rawPath": "/my/path",
    "rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value",
    "requestContext": {
        "accountId": "123456789012",
        "apiId": "<urlid>",
        "domainName": "<url-id>.lambda-url.us-west-2.on.aws",
        "domainPrefix": "<url-id>",
        "http": {
            "method": "POST",
            "path": "/my/path",
            "protocol": "HTTP/1.1",
            "sourceIp": "123.123.123.123",
            "userAgent": "agent",
        },
        "requestId": "id",
        "routeKey": "$default",
        "stage": "$default",
        "time": "12/Mar/2020:19:03:58 +0000",
        "timeEpoch": 1583348638390,
    },
    "routeKey": "$default",
    "version": "2.0",
}

lb = boto3.client("lambda", endpoint_url=os.environ.get("MOTO_ENDPOINT_URL"))
ecs = boto3.client("ecs", endpoint_url=os.environ.get("ECS_ENDPOINT_URL"))


def get_sig(body: dict, ssm_key: str) -> str:
    """Generates GitHub SHA-256 signature based on passed body"""
    if os.environ.get("IS_REMOTE"):
        ssm = boto3.client("ssm")
    else:
        ssm = boto3.client("ssm", endpoint_url=os.environ.get("MOTO_ENDPOINT_URL"))

    secret = ssm.get_parameter(Name=ssm_key, WithDecryption=True)["Parameter"]["Value"]

    return hmac.new(
        bytes(str(secret), "utf-8"),
        bytes(json.dumps(body), "utf-8"),
        hashlib.sha256,
    ).hexdigest()


@pytest.fixture(scope="module", autouse=True)
def receiver_url(request, mut_output, docker_lambda_receiver):
    port = "8080"
    alias = "receiver"
    base_env_vars = lb.get_function(FunctionName=mut_output["receiver_function_name"])[
        "Configuration"
    ]["Environment"]["Variables"]

    if os.environ.get("IS_REMOTE"):
        # TODO: create assume role policy in tf fixture dir to allow IAM user associated with dev container to assume
        # receiver role
        sts = boto3.client("sts")
        creds = sts.assume_role(
            RoleArn=mut_output["receiver_role_arn"],
            RoleSessionName=f"Integration-{uuid.uuid4()}",
        )["Credentials"]

        testing_env_vars = {
            "AWS_ACCESS_KEY_ID": creds["AccessKeyId"],
            "AWS_SECRET_ACCESS_KEY": creds["SecretAccessKey"],
            "AWS_SESSION_TOKEN": creds["SessionToken"],
            "AWS_REGION": mut_output["aws_region"],
            "AWS_DEFAULT_REGION": mut_output["aws_region"],
        }
    else:
        testing_env_vars = {
            "AWS_ACCESS_KEY_ID": "mock-key",
            "AWS_SECRET_ACCESS_KEY": "mock-secret-key",
            "AWS_REGION": mut_output["aws_region"],
            "AWS_DEFAULT_REGION": mut_output["aws_region"],
            "SSM_ENDPOINT_URL": os.environ.get("MOTO_ENDPOINT_URL", ""),
            "ECS_ENDPOINT_URL": os.environ.get("ECS_ENDPOINT_URL", ""),
        }

    container = docker.run(
        image=docker_lambda_receiver,
        envs={**base_env_vars, **testing_env_vars},
        publish=[(port,)],
        networks=[os.environ["NETWORK_NAME"]],
        network_aliases=[alias],
        detach=True,
    )

    yield f"http://{alias}:{port}/2015-03-31/functions/function/invocations"

    docker.container.stop(container, time=None)

    # if any test(s) failed, keep container to access docker logs for debugging
    if not getattr(request.node.obj, "any_failures", False):
        docker.container.remove(container, force=True)


@pytest.fixture()
def base_pr_event(pr):
    """Base event with PR event attributes"""
    event = base_event.copy()

    event["body"]["pull_request"]["base"] = {
        "sha": pr["base_commit_id"],
        "ref": pr["base_ref"],
    }
    event["body"]["pull_request"]["head"] = {
        "sha": pr["head_commit_id"],
        "ref": pr["head_ref"],
    }
    event["body"]["pull_request"]["number"] = pr["number"]
    event["body"]["repository"]["full_name"] = pr["full_name"]

    return event


@pytest.fixture()
def merge_event(base_pr_event, mut_output):
    """Updates event with merged PR event attributes"""
    base_pr_event["body"]["pull_request"]["merged"] = True
    base_pr_event["body"]["action"] = "closed"

    valid_sig = get_sig(
        base_pr_event.get("body"), mut_output["github_webhook_secret_ssm_key"]
    )
    base_pr_event["headers"]["x-hub-signature-256"] = "sha256=" + valid_sig
    base_pr_event["body"] = json.dumps(base_pr_event["body"])

    return base_pr_event


@pytest.fixture()
def open_pr_event(base_pr_event, mut_output):
    """Updates event with open PR event attributes"""
    base_pr_event["body"]["pull_request"]["merged"] = False
    base_pr_event["body"]["action"] = "opened"

    valid_sig = get_sig(
        base_pr_event.get("body"), mut_output["github_webhook_secret_ssm_key"]
    )
    base_pr_event["headers"]["x-hub-signature-256"] = "sha256=" + valid_sig

    base_pr_event["body"] = json.dumps(base_pr_event["body"])

    return base_pr_event


@pytest.mark.parametrize(
    "pr",
    [
        {
            "base_ref": "master",
            "head_ref": "feature-" + str(uuid.uuid4()),
            "changes": {"foo.txt": "bar"},
        }
    ],
    indirect=True,
)
def test_handler_invalid_sig(mut_output, open_pr_event, repo, pr, receiver_url):
    """Request contains invalid GitHub signature"""
    open_pr_event["headers"]["x-hub-signature-256"] = "invalid-sig"
    res = requests.post(receiver_url, json=open_pr_event).json()

    assert res["statusCode"] == 403
    assert json.loads(res["body"])["message"] == "Signature is not a valid sha256 value"


@pytest.mark.parametrize(
    "pr",
    [
        {
            "base_ref": "master",
            "head_ref": "feature-" + str(uuid.uuid4()),
            "changes": {"foo.txt": "bar"},
        }
    ],
    indirect=True,
)
def test_invalid_filepaths(mut_output, open_pr_event, repo, pr, receiver_url):
    """GitHub event does not meet file path constraint"""
    res = requests.post(receiver_url, json=open_pr_event).json()
    log.debug(res)
    assert res["statusCode"] == 200
    assert (
        json.loads(res["body"])["message"].strip()
        == f"No diff filepath was matched within pattern: {mut_output['file_path_pattern']}".strip()
    )

    tasks = ecs.list_tasks(
        cluster=mut_output["ecs_cluster_arn"],
        launchType="FARGATE",
        startedBy=pr["head_commit_id"],
        family=mut_output["ecs_pr_plan_family"],
    )["taskArns"]

    assert len(tasks) == 0


@pytest.mark.parametrize(
    "pr",
    [
        {
            "base_ref": "master",
            "head_ref": "feature-" + str(uuid.uuid4()),
            "changes": {
                "directory_dependency/dev-account/us-west-2/env-one/doo/main.tf": "bar"
            },
        }
    ],
    indirect=True,
)
def test_create_deploy_stack_success(mut_output, merge_event, repo, pr, receiver_url):
    """Lambda Function should run the Create Deploy Stack task once for the valid merge event"""
    res = requests.post(receiver_url, json=merge_event).json()

    assert res["statusCode"] == 200
    assert json.loads(res["body"])["message"] == "Request was successful"

    tasks = ecs.list_tasks(
        cluster=mut_output["ecs_cluster_arn"],
        launchType="FARGATE",
        startedBy=pr["head_commit_id"],
        family=mut_output["ecs_create_deploy_stack_family"],
    )["taskArns"]

    assert len(tasks) == 1


@pytest.mark.parametrize(
    "pr",
    [
        {
            "base_ref": "master",
            "head_ref": "feature-" + str(uuid.uuid4()),
            "changes": {
                "directory_dependency/dev-account/us-west-2/env-one/doo/main.tf": "bar"
            },
        }
    ],
    indirect=True,
)
def test_pr_plan_success(mut_output, open_pr_event, repo, pr, receiver_url):
    """Lambda Function should run the PR Plan task for each selected directory witin the valid open PR event"""
    res = requests.post(receiver_url, json=open_pr_event).json()

    assert res["statusCode"] == 200
    assert json.loads(res["body"])["message"] == "Request was successful"

    tasks = ecs.list_tasks(
        cluster=mut_output["ecs_cluster_arn"],
        launchType="FARGATE",
        startedBy=pr["head_commit_id"],
        family=mut_output["ecs_pr_plan_family"],
    )["taskArns"]

    assert len(tasks) == 2
