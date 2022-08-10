from tests.e2e import base_e2e
from tests.helpers.utils import dummy_tf_output
import uuid


class TestSucceededDeployment(base_e2e.E2E):
    """
    Case covers a simple 2 node deployment with one node having an account-level dependency on the other.
    See the account_dim table to see the account dependency testing layout.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/shared-services-account/us-west-2/env-one/doo": {
                "actions": {"apply": "approve"},
                "pr_files_content": [
                    dummy_tf_output(),
                    dummy_tf_output(),
                    dummy_tf_output(),
                ],
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "actions": {"apply": "approve"},
                "pr_files_content": [dummy_tf_output()],
            },
        },
    }


class TestRejectedDeployment(base_e2e.E2E):
    """
    Case covers a simple 2 node deployment with one node having an account-level dependency on the other.
    See the account_dim table to see the account dependency testing layout.
    The rejection of the first deployment's approval should cause the second planned deployment to be aborted
    and not have an associated Step Function execution created.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/shared-services-account/us-west-2/env-one/doo": {
                "actions": {"apply": "reject"},
                "pr_files_content": [dummy_tf_output()],
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "sf_execution_exists": False,
                "pr_files_content": [dummy_tf_output()],
            },
        },
    }
