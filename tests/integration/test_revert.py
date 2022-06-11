from tests.integration import test_integration
import uuid
from tests.helpers.utils import null_provider_resource
import os


class TestBasePR(test_integration.Integration):
    """
    Case covers a simple 3 node deployment containing one modified directory. The purpose
    of this PR is to deploy a new provider resource which creates a base Terraform remote state
    for the next PR class below.
    """

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/dev-account/us-west-2/env-one/baz": {
                "actions": {"deploy": "approve"},
                "pr_files_content": [null_provider_resource],
            },
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"deploy": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "actions": {"deploy": "approve"}
            },
        },
    }


class TestDeployPR(test_integration.Integration):
    """
    Case covers a 5 node deployment with 2 modified directories. One of the deployments will be rejected causing
    the directory with new provider resources to be rolled back. The purpose of this case is
    to ensure that the new provider resources introduced from the previous PR are not rolled back
    while the new provider resources introduced in this PR are rolled back.
    """

    cls_depends_on = [f"./{os.path.basename(__file__)}::TestBasePR"]

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "executions": {
            "directory_dependency/dev-account/global": {
                "actions": {"deploy": "approve", "rollback_providers": "approve"},
                "pr_files_content": [null_provider_resource],
            },
            "directory_dependency/dev-account/us-west-2/env-one/baz": {
                "actions": {"deploy": "approve"},
                "pr_files_content": ['resource "null_resource" "baz" {}'],
            },
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"deploy": "reject"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "actions": {"deploy": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "sf_execution_exists": False
            },
        },
    }


class TestRevertPR(test_integration.Integration):
    """
    Case covers a 5 node deployment containing no new modified directories other than the revert changes for the previous PR.
    This case will create a revert PR that will contain the base ref version of the repo that was compared to the previous PR defined above.
    """

    cls_depends_on = [f"./{os.path.basename(__file__)}::TestDeployPR"]
    case = {
        "head_ref": f'revert-{TestDeployPR.case["head_ref"]}',
        "revert_ref": TestDeployPR.case["head_ref"],
        "executions": {
            "directory_dependency/dev-account/global": {
                "actions": {"deploy": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/doo": {
                "actions": {"deploy": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/baz": {
                "actions": {"deploy": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/bar": {
                "actions": {"deploy": "approve"}
            },
            "directory_dependency/dev-account/us-west-2/env-one/foo": {
                "actions": {"deploy": "approve"}
            },
        },
    }
