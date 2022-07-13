from tests.integration import test_integration
from tests.helpers.utils import dummy_tf_output
import uuid
import logging
import pytest
import json
import boto3

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TestCreateDeployStackRollback(test_integration.Integration):
    """
    Case covers a simple 2 node deployment with one node having an account-level dependency on the other.
    See the account_dim table to see the account dependency testing layout.
    The error caused by the invalid Terraform configuration(s) within the dev-account should cause the create_deploy_stack.py script to
    rollback the shared-services account's execution records and fail the build entirely without any other downstream services being invoked.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "expect_failed_create_deploy_stack": True,
        "executions": {
            "directory_dependency/shared-services-account/us-west-2/env-one/doo": {
                "pr_files_content": [dummy_tf_output()]
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "pr_files_content": [dummy_tf_output()]
            },
        },
    }

    @pytest.fixture(scope="class", autouse=True)
    def remove_iam_role(self, mut_output):
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
                            "Resource": mut_output["secondary_test_plan_role_arn"],
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
