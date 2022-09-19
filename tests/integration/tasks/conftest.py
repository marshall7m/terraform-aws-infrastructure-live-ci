import os
import pytest
import logging
import uuid
import github
from tests.helpers.utils import push

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def pytest_generate_tests(metafunc):
    if "terra" in metafunc.fixturenames:
        metafunc.parametrize(
            "terra",
            [
                pytest.param(
                    {
                        "binary": "terragrunt",
                        "skip_teardown": True,
                        "env": {
                            "TF_VAR_approval_sender_arn": "arn:aws:ses:us-west-2:123456789012:identity/fakesender@fake.com",
                            "TF_VAR_approval_request_sender_email": "fakesender@fake.com",
                            "TF_VAR_create_approval_sender_policy": "false",
                        },
                        "tfdir": f"{os.path.dirname(os.path.realpath(__file__))}/../../fixtures/terraform/mut/basic",
                    },
                )
            ],
            indirect=True,
            scope="session",
        )
    if "terra_setup" in metafunc.fixturenames:
        metafunc.parametrize(
            "terra_setup", [{"cleanup_on_exit": False}], indirect=True, scope="session"
        )
        # metafunc.parametrize("terra_setup", [{"cleanup_on_exit": os.environ.get("IS_REMOTE") == None}], indirect=True, scope="session")


@pytest.fixture()
def mut_output(terra_apply, terra_output):
    return {k: v["value"] for k, v in terra_output.items()}


@pytest.fixture
def push_changes(mut_output, request):
    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"])
    branch = f"test-{uuid.uuid4()}"
    repo = gh.get_repo(mut_output["repo_full_name"])

    yield {"commit_id": push(repo, branch, request.param), "branch": branch}

    log.debug(f"Deleting branch: {branch}")
    ref = repo.get_git_ref(f"heads/{branch}")
    ref.delete()
