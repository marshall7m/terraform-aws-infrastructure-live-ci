import os
import logging

import pytest
import github
from tests.helpers.utils import commit

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)


@pytest.fixture(scope="function")
def aws_credentials():
    """
    Mocked AWS credentials needed to be set before importing Lambda Functions that define global boto3 clients.
    This prevents the region_name not specified errors.
    """
    os.environ["AWS_ACCESS_KEY_ID"] = os.environ.get("AWS_ACCESS_KEY_ID", "testing")
    os.environ["AWS_SECRET_ACCESS_KEY"] = os.environ.get(
        "AWS_SECRET_ACCESS_KEY", "testing"
    )
    os.environ["AWS_SECURITY_TOKEN"] = os.environ.get("AWS_SECURITY_TOKEN", "testing")
    os.environ["AWS_SESSION_TOKEN"] = os.environ.get("AWS_SESSION_TOKEN", "testing")
    os.environ["AWS_REGION"] = os.environ.get("AWS_REGION", "us-west-2")
    os.environ["AWS_DEFAULT_REGION"] = os.environ.get("AWS_DEFAULT_REGION", "us-west-2")


class ServerException(Exception):
    pass


@pytest.fixture(scope="module")
def repo(request):
    log.info(f"Creating repo from template: {request.param}")
    repo = gh.get_repo(request.param)
    repo = gh.get_user().create_repo_from_template(request.param, repo)

    yield repo

    log.info(f"Deleting repo: {request.param}")
    repo.delete()


@pytest.fixture
def pr(repo, request):
    """
    Creates the PR used for testing the function calls to the GitHub API.
    Current implementation creates all PR changes within one commit.
    """

    param = request.param[0]
    base_commit = repo.get_branch(param["base_ref"])
    head_ref = repo.create_git_ref(
        ref="refs/heads/" + param["head_ref"], sha=base_commit.commit.sha
    )
    commit_id = commit(
        repo, param["head_ref"], param["changes"], param["commit_message"]
    ).sha
    head_ref.edit(sha=commit_id)

    log.info("Creating PR")
    pr = repo.create_pull(
        title=param.get("title", f"test-{param['head_ref']}"),
        body=param.get("body", "Test PR"),
        base=param["base_ref"],
        head=param["head_ref"],
    )

    yield {
        "number": pr.number,
        "head_commit_id": commit_id,
        "base_ref": param["base_ref"],
        "head_ref": param["head_ref"],
    }

    log.info(f"Removing PR head ref branch: {param['head_ref']}")
    head_ref.delete()

    log.info(f"Closing PR: #{pr.number}")
    try:
        pr.edit(state="closed")
    except Exception:
        log.info("PR is merged or already closed")
