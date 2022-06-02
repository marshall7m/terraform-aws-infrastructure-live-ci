from tests.integration import test_integration
import uuid
from tests.helpers.utils import dummy_tf_output, null_provider_resource


class TestRejectRollbackProvider(test_integration.Integration):
    """
    Case covers a simple 2 node deployment with each having no account-level dependencies and
    the second deployment having a dependency on the first one.
    The first deployment will be approved while the second deployment will be rejected.
    The rejection of the second deployment will cause the first deployment to have a
    rollback new provider resources deployment (see "Rollback New Provider Resources" section of README.md for more details).
    The rollback deployment will be rejected and the trigger Step Function Lambda is then expected to fail.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"deploy": "approve", "rollback_providers": "reject"},
                "pr_files_content": [null_provider_resource],
                "expect_failed_rollback_providers_cw_trigger_sf": True,
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "actions": {"deploy": "reject"},
                "pr_files_content": [dummy_tf_output()],
            },
        },
    }
