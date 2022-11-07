import os
import logging
import uuid
import time
import json

import pytest
from python_on_whales import docker
import boto3
import requests
import aurora_data_api

from functions.approval_response.utils import (
    get_email_approval_sig,
    aws_decode,
    aws_encode,
)
from tests.helpers.utils import insert_records, get_sf_approval_state_msg

log = logging.getLogger("tftest")
log.setLevel(logging.DEBUG)

rds_data_client = boto3.client(
    "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
)
ssm = boto3.client("ssm", endpoint_url=os.environ.get("SSM_ENDPOINT_URL"))

ses_event = {
    "body": "{}",
    "headers": {},
    "isBase64Encoded": False,
    "queryStringParameters": {},
    "rawPath": "/ses",
    "rawQueryString": "parameter1=value1&parameter1=value2&parameter2=value",
    "requestContext": {
        "accountId": "123456789012",
        "apiId": "<urlid>",
        "domainName": "<url-id>.lambda-url.us-west-2.on.aws",
        "domainPrefix": "<url-id>",
        "http": {
            "method": "POST",
            "path": "/ses",
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
sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))


@pytest.fixture(scope="module", autouse=True)
def approval_response_url(request, mut_output, docker_lambda_approval_response):
    port = "8080"
    alias = "approval_response"
    base_env_vars = lb.get_function(
        FunctionName=mut_output["approval_response_function_name"]
    )["Configuration"]["Environment"]["Variables"]

    if os.environ.get("IS_REMOTE"):
        # TODO: create assume role policy in tf fixture dir to allow IAM user associated with dev container to assume
        # lambda role
        sts = boto3.client("sts")
        creds = sts.assume_role(
            RoleArn=mut_output["approval_response_role_arn"],
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
            "METADB_ENDPOINT_URL": os.environ.get("METADB_ENDPOINT_URL", ""),
            "SF_ENDPOINT_URL": os.environ.get("SF_ENDPOINT_URL", ""),
            "SSM_ENDPOINT_URL": os.environ.get("MOTO_ENDPOINT_URL", ""),
        }

    container = docker.run(
        image=docker_lambda_approval_response,
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


@pytest.mark.usefixtures("mock_sf_cfg")
def test_handler_invalid_ses_sig(approval_response_url):
    """Request contains invalid GitHub signature"""
    ses_event["queryStringParameters"]["taskToken"] = "token-123"
    ses_event["queryStringParameters"]["recipient"] = "voter-123"
    ses_event["queryStringParameters"]["action"] = "approve"
    ses_event["queryStringParameters"]["ex"] = "run-123"
    ses_event["queryStringParameters"]["exArn"] = "arn-123"
    ses_event["queryStringParameters"]["X-SES-Signature-256"] = "invalid-sig"

    res = requests.post(approval_response_url, json=ses_event).json()
    log.debug(res)
    assert json.loads(res["body"])["message"] == "Signature is not a valid sha256 value"
    assert res["statusCode"] == 403


@pytest.mark.usefixtures("truncate_executions", "mock_sf_cfg")
def test_handler_vote_count_met(mut_output, approval_response_url):
    """
    Send approval request that should update the approval count and send a
    success Step Function task token
    """
    execution_id = "run-123"
    action = "approve"
    case = "TestApprovalRequest"

    record = insert_records(
        "executions",
        [
            {
                "execution_id": execution_id,
                "approval_voters": [],
                "min_approval_count": 1,
            }
        ],
        enable_defaults=True,
    )

    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(
            {
                "plan_command": "terraform plan",
                "apply_command": "terraform apply -auto-approve",
                "apply_role_arn": "apply-role-arn",
                "cfg_path": "foo/bar",
                "execution_id": "run-123",
                "is_rollback": False,
                "new_providers": [],
                "plan_role_arn": "plan-role-arn",
                "commit_id": "commit-123",
                "account_name": "dev",
                "pr_id": 1,
                "voters": ["voter-1"],
            }
        ),
    )["executionArn"]

    time.sleep(5)

    events = sf.get_execution_history(executionArn=arn, includeExecutionData=True)[
        "events"
    ]
    from pprint import pformat

    log.debug(pformat(events))

    # Give mock execution time to finish
    time.sleep(5)

    msg = get_sf_approval_state_msg(arn)
    recipient = msg["Voters"][0]
    ses_event["queryStringParameters"]["taskToken"] = msg["TaskToken"]
    ses_event["queryStringParameters"]["recipient"] = aws_encode(recipient)
    ses_event["queryStringParameters"]["action"] = action
    ses_event["queryStringParameters"]["ex"] = execution_id
    ses_event["queryStringParameters"]["exArn"] = "arn-123"
    ses_event["queryStringParameters"][
        "X-SES-Signature-256"
    ] = "sha256=" + get_email_approval_sig(
        secret=mut_output["approval_response_ses_secret"],
        execution_id=execution_id,
        recipient=aws_decode(recipient),
        action=action,
    )

    res = requests.post(approval_response_url, json=ses_event).json()
    log.debug(res)
    assert json.loads(res["body"])["message"] == "Vote was successfully submitted"
    assert res["statusCode"] == 200

    log.info("Assert approval count was updated")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute(
            f"""
        SELECT approval_voters
        FROM executions
        WHERE execution_id = '{execution_id}'
        """
        )

        record = cur.fetchone()

    assert record[0] == [recipient]

    status = "RUNNING"
    while status == "RUNNING":
        time.sleep(3)
        status = sf.describe_execution(executionArn=arn)["status"]

    assert sf.describe_execution(executionArn=arn)["output"]["status"] == "succeeded"
    assert status == "SUCCEEDED"


@pytest.mark.usefixtures("truncate_executions", "mock_sf_cfg")
def test_handler_vote_count_not_met(mut_output, approval_response_url):
    execution_id = "run-123"
    recipient = "voter-123"
    case = "TestApprovalRequest"

    insert_records(
        "executions",
        [
            {
                "execution_id": execution_id,
                "approval_voters": [],
                "min_approval_count": 10,
            }
        ],
        enable_defaults=True,
    )

    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(
            {
                "plan_command": "terraform plan",
                "apply_command": "terraform apply -auto-approve",
                "apply_role_arn": "apply-role-arn",
                "cfg_path": "foo/bar",
                "execution_id": execution_id,
                "is_rollback": False,
                "new_providers": [],
                "plan_role_arn": "plan-role-arn",
                "commit_id": "commit-123",
                "account_name": "dev",
                "pr_id": 1,
                "voters": [recipient],
            }
        ),
    )["executionArn"]

    # Give mock execution time to finish
    time.sleep(5)

    msg = get_sf_approval_state_msg(arn)
    recipient = msg["Voters"][0]

    ses_event["queryStringParameters"]["taskToken"] = msg["TaskToken"]
    ses_event["queryStringParameters"]["recipient"] = recipient
    ses_event["queryStringParameters"]["action"] = "approve"
    ses_event["queryStringParameters"]["ex"] = execution_id
    ses_event["queryStringParameters"]["exArn"] = "arn-123"
    ses_event["queryStringParameters"][
        "X-SES-Signature-256"
    ] = "sha256=" + get_email_approval_sig(
        secret=mut_output["approval_response_ses_secret"],
        execution_id=ses_event["queryStringParameters"]["ex"],
        recipient=ses_event["queryStringParameters"]["recipient"],
        action=ses_event["queryStringParameters"]["action"],
    )

    res = requests.post(approval_response_url, json=ses_event).json()

    log.debug(res)
    assert json.loads(res["body"])["message"] == "Vote was successfully submitted"
    assert res["statusCode"] == 200

    time.sleep(5)

    assert sf.describe_execution(executionArn=arn)["status"] == "RUNNING"


@pytest.mark.usefixtures("truncate_executions", "mock_sf_cfg")
def test_handler_expired_vote(mut_output, approval_response_url):
    case = "CompleteSuccess"
    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=json.dumps(
            {
                "plan_command": "terraform plan",
                "apply_command": "terraform apply -auto-approve",
                "apply_role_arn": "apply-role-arn",
                "cfg_path": "foo/bar",
                "execution_id": "run-123",
                "is_rollback": False,
                "new_providers": [],
                "plan_role_arn": "plan-role-arn",
                "commit_id": "commit-123",
                "account_name": "dev",
                "pr_id": 1,
                "voters": ["voter-1"],
            }
        ),
    )["executionArn"]

    ses_event["queryStringParameters"]["taskToken"] = "token-123"
    ses_event["queryStringParameters"]["recipient"] = "voter-123"
    ses_event["queryStringParameters"]["action"] = "approve"
    ses_event["queryStringParameters"]["ex"] = "run-123"
    ses_event["queryStringParameters"]["exArn"] = "arn-123"
    ses_event["queryStringParameters"][
        "X-SES-Signature-256"
    ] = "sha256=" + get_email_approval_sig(
        secret=mut_output["approval_response_ses_secret"],
        execution_id=ses_event["queryStringParameters"]["ex"],
        recipient=ses_event["queryStringParameters"]["recipient"],
        action=ses_event["queryStringParameters"]["action"],
    )

    status = "RUNNING"
    while status == "RUNNING":
        time.sleep(3)
        status = sf.describe_execution(executionArn=arn)["status"]

    res = requests.post(approval_response_url, json=ses_event).json()
    log.debug(res)
    assert (
        json.loads(res["body"])["message"]
        == "Approval submissions are not available anymore -- Execution Status: "
        + status
    )
    assert res["statusCode"] == 410
