import os
import logging
import time
import uuid

import pytest
import github
from tests.helpers.utils import commit

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

gh = github.Github(os.environ["GITHUB_TOKEN"], retry=3)


class ServerException(Exception):
    pass


@pytest.fixture(scope="module")
def repo(request):
    log.info(f"Creating repo from template: {request.param}")
    repo = gh.get_repo(request.param)
    repo = gh.get_user().create_repo_from_template(
        "test-infra-live-" + str(uuid.uuid4()), repo
    )
    # needs to wait or else raises error on empty repo
    time.sleep(5)
    repo.edit(default_branch="master")

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
