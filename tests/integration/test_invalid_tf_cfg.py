from tests.integration import test_integration
from tests.helpers.utils import dummy_tf_output
import uuid


class TestInvalidTFConfig(test_integration.Integration):
    """
    Case covers a simple 2 node deployment with one node having an account-level dependency on the other.
    See the account_dim table to see the account dependency testing layout.
    The error caused by the invalid Terraform configuration(s) within the dev-account should cause the create_deploy_stack.py script to
    rollback the shared-services account's execution records and fail the build entirely without any other downstream services being invoked.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "expect_failed_pr_plan": True,
        "executions": {
            "directory_dependency/shared-services-account/us-west-2/env-one/doo": {
                "pr_files_content": [dummy_tf_output()]
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "sf_execution_exists": False,
                "expect_failed_pr_plan": True,
                "pr_files_content": [dummy_tf_output(name="1_invalid_name")],
            },
        },
    }
