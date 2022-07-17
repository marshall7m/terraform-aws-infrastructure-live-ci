import pytest
import os
from slack.approval_request import ApprovalRequest
from slack.app import send_approval
from urllib.parse import quote_plus
import requests

@pytest.fixture(scope="module", autouse=True)
@pytest.mark.parametrize(
    "terraform_version,tf",
    [
        (
            "1.0.0",
            f"{os.path.dirname(os.path.realpath(__file__))}/fixtures",
        )
    ],
    indirect=True,
)
def mut_output(tf, terraform_version, repo):
    """
    Creates AWS API Gateway and Lambda Function Terraform resources for approval flow
    """
    tf.init()
    log.info("Applying testing tf module")
    tf.apply(auto_approve=True)

    yield {k: v["value"] for k, v in tf.output().items()}
    tf.destroy(auto_approve=True)


def test_approval_requests(mut_output):
    # send_approval(os.environ["SLACK_CHANNEL"])
    pass

def test_approved():
    pass
