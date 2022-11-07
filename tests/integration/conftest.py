import os
import logging
import uuid

import pytest
import github

from tests.helpers.utils import push

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture
def push_changes(mut_output, request):
    gh = github.Github(login_or_token=os.environ["GITHUB_TOKEN"], retry=3)
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
