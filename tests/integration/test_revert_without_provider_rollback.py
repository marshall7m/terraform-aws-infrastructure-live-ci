import uuid
import logging
import os
import pytest
import boto3
from tests.helpers.utils import dummy_configured_provider_resource
from tests.integration import test_integration

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


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


@pytest.mark.regex_dependency(
    f"{os.path.splitext(os.path.basename(__file__))[0]}\.py::TestDeployPR::.+",
    allowed_outcomes=["passed", "skipped"],
)
class TestRevertPRWithoutProviderRollback(test_integration.Integration):
    """
    Case will merge a PR that will revert the changes from the upstream case's PR.
    This case's associated create deploy stack Codebuild is expected to fail given
    that the reversion of the PR will remove not only the new dummy resource block
    but also it's respective dummy provider block that Terraform needs in order to destroy
    the dummy resource.
    """

    @pytest.fixture(scope="class", autouse=True)
    def unset_graph_scan(self, mut_output):
        cb = boto3.client("codebuild")

        current = cb.batch_get_projects(
            names=[mut_output["codebuild_create_deploy_stack_name"]]
        )["projects"][0]
        original = current["environment"]
        current["environment"]["environmentVariables"] = [
            env_var
            for env_var in current["environment"]["environmentVariables"]
            if env_var["name"] != "GRAPH_SCAN"
        ]
        cb.update_project(
            name=mut_output["codebuild_create_deploy_stack_name"],
            environment=current["environment"],
        )

        yield None

        cb.update_project(
            name=mut_output["codebuild_create_deploy_stack_name"], environment=original
        )

    case = {
        "head_ref": f"feature-{uuid.uuid4()}",
        "revert_ref": TestDeployPR.case["head_ref"],
        "expect_failed_create_deploy_stack": True,
        "executions": {},
    }
