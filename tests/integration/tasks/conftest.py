import os
import logging
import uuid

import pytest
import github
import tftest
from tests.helpers.utils import push

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture()
def mut_output():
    tf = tftest.TerragruntTest(
        binary="terragrunt",
        env={
            "TF_VAR_approval_sender_arn": "arn:aws:ses:us-west-2:123456789012:identity/fakesender@fake.com",
            "TF_VAR_approval_request_sender_email": "fakesender@fake.com",
            "TF_VAR_create_approval_sender_policy": "false",
        },
        tfdir=f"{os.path.dirname(os.path.realpath(__file__))}/../../fixtures/terraform/mut/basic",
        enable_cache=True,
    )

    tf.setup(cleanup_on_exit=True, use_cache=True)
    tf.apply(auto_approve=True, use_cache=True)

    return {k: v["value"] for k, v in tf.output(use_cache=True).items()}


@pytest.fixture
def push_changes(mut_output, request):
    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])
    branch = f"test-{uuid.uuid4()}"
    repo = gh.get_repo(mut_output["repo_full_name"])

    yield {
        "commit_id": push(repo, branch, request.param),
        "branch": branch,
        "changes": request.param,
    }

    log.debug(f"Deleting branch: {branch}")
    ref = repo.get_git_ref(f"heads/{branch}")
    ref.delete()
