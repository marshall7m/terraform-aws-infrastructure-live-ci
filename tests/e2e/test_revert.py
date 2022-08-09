from tests.e2e import test_integration
import uuid
from tests.helpers.utils import null_provider_resource
import os
import pytest


class TestBasePR(base_e2e.E2E):
    """
    Case covers a simple 3 node deployment containing one modified directory. The purpose
    of this PR is to deploy a new provider resource which creates a base Terraform remote state
    for the next PR class below.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/dev-account/us-west-2/env-one/baz": {
                "actions": {"apply": "approve"},
                "pr_files_content": [null_provider_resource],
            },
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"apply": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "actions": {"apply": "approve"}
            },
        },
    }


@pytest.mark.regex_dependency(
    f"{os.path.splitext(os.path.basename(__file__))[0]}\.py::TestBasePR::.+",
    allowed_outcomes=["passed", "skipped"],
)
class TestDeployPR(base_e2e.E2E):
    """
    Case covers a 5 node deployment with 2 modified directories. One of the
    deployments will be rejected causing the directory with new provider
    resources to be rolled back. The purpose of this case is to ensure that the
    new provider resources introduced from the previous PR are not rolled back
    while the new provider resources introduced in this PR are rolled back within
    the downstream revert PR.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/dev-account/global": {
                "actions": {"apply": "approve", "rollback_providers": "approve"},
                "pr_files_content": [null_provider_resource],
            },
            "directory_dependency/dev-account/us-west-2/env-one/baz": {
                "actions": {"apply": "approve"},
                "pr_files_content": ['resource "null_resource" "baz" {}'],
            },
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"apply": "reject"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "actions": {"apply": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "sf_execution_exists": False
            },
        },
    }


@pytest.mark.regex_dependency(
    f"{os.path.splitext(os.path.basename(__file__))[0]}\.py::TestDeployPR::.+",
    allowed_outcomes=["passed", "skipped"],
)
class TestRevertPR(base_e2e.E2E):
    """
    Case covers a 5 node deployment containing no new modified directories other
    than the revert changes for the previous PR. This case will create a PR to
    revert the changes introduced within the previous PR.
    """

    case = {
        "head_ref": f'revert-{TestDeployPR.case["head_ref"]}',
        "revert_ref": TestDeployPR.case["head_ref"],
        "executions": {
            "directory_dependency/dev-account/global": {
                "actions": {"apply": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "actions": {"apply": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/baz": {
                "actions": {"apply": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"apply": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "actions": {"apply": "approve"}
            },
        },
    }
