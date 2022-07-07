import uuid
import logging
import os
import pytest
import boto3
from tests.helpers.utils import dummy_configured_provider_resource
from tests.integration import test_integration

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.mark.skip("See class case TODO")
class TestDeployPR(test_integration.Integration):
    """
    Case covers a simple one node deployment that contains a new dummy
    provider resource.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "actions": {"deploy": "approve"},
                "pr_files_content": [dummy_configured_provider_resource],
            }
        },
        "destroy_tf_resources_with_pr": True,
    }


@pytest.mark.skip("See upstream class case TODO")
@pytest.mark.regex_dependency(
    f"{os.path.splitext(os.path.basename(__file__))[0]}\.py::TestDeployPR::.+",
    allowed_outcomes=["passed", "skipped"],
)
class TestRevertPRWithoutProviderRollback(test_integration.Integration):
    """
    Case will merge a PR that will revert the changes from the upstream case's PR.
    This case's associated create deploy stack task is expected to fail given
    that the reversion of the PR will remove not only the new dummy resource block
    but also it's respective dummy provider block that Terraform needs in order to destroy
    the dummy resource. The task is specifically expected to fail when SCAN_TYPE is set to `plan`
    and uses `terragrunt run-all plan` to collect deployment directories
    rather than `terragrunt graph-dependencies`.
    """

    case = {
        "scan_type": "plan",
        "head_ref": f"feature-{uuid.uuid4()}",
        "revert_ref": TestDeployPR.case["head_ref"],
        "expect_failed_create_deploy_stack": True,
        "executions": {},
    }
