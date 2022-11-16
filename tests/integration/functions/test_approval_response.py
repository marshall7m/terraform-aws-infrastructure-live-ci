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
    aws_encode,
)
from tests.helpers.utils import insert_records, get_sf_approval_state_msg

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

rds_data_client = boto3.client(
    "rds-data", endpoint_url=os.environ.get("METADB_ENDPOINT_URL")
)
ssm = boto3.client("ssm", endpoint_url=os.environ.get("SSM_ENDPOINT_URL"))

execution_id = "run-123"

ses_event = {
    "body": "{}",
    "headers": {},
    "isBase64Encoded": False,
    "queryStringParameters": {
        "taskToken": "token-123",
        "recipient": aws_encode("voter-123"),
        "action": "approve",
        "ex": execution_id,
        "exArn": "arn-123",
    },
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
sf_input = json.dumps(
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
        "voters": [ses_event["queryStringParameters"]["recipient"]],
    }
)

lb = boto3.client("lambda", endpoint_url=os.environ.get("MOTO_ENDPOINT_URL"))
sf = boto3.client("stepfunctions", endpoint_url=os.environ.get("SF_ENDPOINT_URL"))


@pytest.fixture(scope="module", autouse=True)
def approval_response_url(request, mut_output, docker_lambda_approval_response):
    """Starts the Lambda Function within a docker container and yields the invoke URL"""
    port = "8080"
    alias = "approval_response"
    base_env_vars = lb.get_function(
        FunctionName=mut_output["approval_response_function_name"]
    )["Configuration"]["Environment"]["Variables"]

    if os.environ.get("IS_REMOTE"):
        pytest.skip("Integration test is not supported remotely")
    else:
        testing_env_vars = {
            "AWS_ACCESS_KEY_ID": "mock-key",
            "AWS_SECRET_ACCESS_KEY": "mock-secret-key",
            "AWS_REGION": mut_output["aws_region"],
            "AWS_DEFAULT_REGION": mut_output["aws_region"],
            "METADB_ENDPOINT_URL": os.environ.get("METADB_ENDPOINT_URL", ""),
            "SF_ENDPOINT_URL": os.environ.get("SF_ENDPOINT_URL", ""),
            "SSM_ENDPOINT_URL": os.environ.get("MOTO_ENDPOINT_URL", ""),
            "AURORA_CLUSTER_ARN": os.environ.get("AURORA_CLUSTER_ARN"),
            "AURORA_SECRET_ARN": os.environ.get("AURORA_SECRET_ARN"),
            "METADB_NAME": os.environ.get("METADB_NAME"),
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
    """Test request that contains invalid authorization signature"""
    ses_event["queryStringParameters"]["X-SES-Signature-256"] = "invalid-sig"

    res = requests.post(approval_response_url, json=ses_event).json()
    log.debug(res)
    assert json.loads(res["body"])["message"] == "Signature is not a valid sha256 value"
    assert res["statusCode"] == 403


@pytest.mark.usefixtures("truncate_executions", "mock_sf_cfg")
def test_handler_vote_count_met(mut_output, approval_response_url):
    """
    Send approval request that causes the execution to meet it's associated approval count
    """
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
        input=sf_input,
    )["executionArn"]

    time.sleep(5)

    msg = get_sf_approval_state_msg(arn)

    ses_event["queryStringParameters"]["exArn"] = arn
    ses_event["queryStringParameters"]["taskToken"] = msg["TaskToken"]
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

    assert record[0] == [ses_event["queryStringParameters"]["recipient"]]

    status = "RUNNING"
    while status == "RUNNING":
        time.sleep(3)
        status = sf.describe_execution(executionArn=arn)["status"]
    assert status == "SUCCEEDED"

    assert (
        json.loads(sf.describe_execution(executionArn=arn)["output"])["status"]
        == "succeeded"
    )


@pytest.mark.usefixtures("truncate_executions", "mock_sf_cfg")
def test_handler_vote_count_not_met(mut_output, approval_response_url):
    """
    Send approval request that doesn't cause the execution to meet it's associated approval count
    """
    insert_records(
        "executions",
        [
            {
                "execution_id": execution_id,
                "approval_voters": [],
                "min_approval_count": 10,  # min approval count should not be met
            }
        ],
        enable_defaults=True,
    )

    case = "TestApprovalRequest"
    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=sf_input,
    )["executionArn"]

    time.sleep(5)

    ses_event["queryStringParameters"]["exArn"] = arn
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

    time.sleep(3)
    # since the approval count isn't met the SF execution should still be running
    assert sf.describe_execution(executionArn=arn)["status"] == "RUNNING"


@pytest.mark.usefixtures("truncate_executions", "mock_sf_cfg")
def test_handler_vote_updated(mut_output, approval_response_url):
    """
    Send approval request for the same voter with different approval action
    """
    insert_records(
        "executions",
        [
            {
                "execution_id": execution_id,
                "rejection_voters": [],
                "approval_voters": [ses_event["queryStringParameters"]["recipient"]],
                "min_rejection_count": 10,
                "min_approval_count": 10,
            }
        ],
        enable_defaults=True,
    )

    case = "TestApprovalRequest"
    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=sf_input,
    )["executionArn"]

    time.sleep(5)

    ses_event["queryStringParameters"]["exArn"] = arn
    ses_event["queryStringParameters"]["action"] = "reject"
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

    log.info("Assert approval_voters and rejection_voters columns were updated")
    with aurora_data_api.connect(
        database=os.environ["METADB_NAME"], rds_data_client=rds_data_client
    ) as conn, conn.cursor() as cur:
        cur.execute(
            f"""
        SELECT approval_voters, rejection_voters
        FROM executions
        WHERE execution_id = '{execution_id}'
        """
        )

        record = cur.fetchone()

    assert record[0] == []
    assert record[1] == [ses_event["queryStringParameters"]["recipient"]]


@pytest.mark.usefixtures("truncate_executions", "mock_sf_cfg")
def test_handler_expired_vote(mut_output, approval_response_url):
    """
    Send approval request to an execution that has already finished
    """
    case = "CompleteSuccess"
    arn = sf.start_execution(
        name=f"test-{case}-{uuid.uuid4()}",
        stateMachineArn=mut_output["step_function_arn"] + "#" + case,
        input=sf_input,
    )["executionArn"]

    ses_event["queryStringParameters"]["exArn"] = arn
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
