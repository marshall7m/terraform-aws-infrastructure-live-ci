from tests.integration import test_integration
from tests.helpers.utils import dummy_configured_provider_resource, dummy_tf_output
import uuid
import logging

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


class TestDeployPR(test_integration.Integration):
    """
    Case covers a simple 2 node deployment with each having no account-level dependencies and
    the second deployment having a dependency on the first one.
    The first deployment will be approved while the second deployment will be rejected.
    The rejection of the second deployment will cause the first deployment to have a
    rollback new provider resources deployment (see "Rollback New Provider Resources" section of README.md for more details).
    The rollback deployment will be approved which will allow the downstream revert PR to be able to freely run deployments
    without having to have the dummy provider block introduced in this PR.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"deploy": "approve", "rollback_providers": "approve"},
                "pr_files_content": [
                    dummy_configured_provider_resource,
                    dummy_tf_output(),
                ],
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "actions": {"deploy": "reject"},
                "pr_files_content": [dummy_tf_output()],
            },
        },
    }


class TestRevertPR(test_integration.Integration):
    """
    Case will merge a PR that will revert the changes from the upstream case's PR. The case covers the same 2 node deployment as above
    but using the base ref version of the above PR.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "revert_ref": TestDeployPR.case["head_ref"],
        "executions": {
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"deploy": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "actions": {"deploy": "approve"}
            },
        },
    }
