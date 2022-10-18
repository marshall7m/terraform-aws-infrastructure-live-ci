import os
import logging
import pytest
import github

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


@pytest.fixture(scope="session")
def gh():
    return github.Github(os.environ["TF_VAR_testing_github_token"], retry=3)


@pytest.fixture(scope="module")
def repo(gh, request):

    if type(request.param) == dict:
        if request.param["is_fork"]:
            log.info(f"Forking repo: {request.param['name']}")
            base = gh.get_repo(request.param["name"])
            repo = gh.get_user().create_fork(base)
    else:
        log.info(f"Creating repo: {request.param}")
        repo = gh.get_user().create_repo(request.param, auto_init=True)

    yield repo

    log.info(f"Deleting repo: {request.param}")
    repo.delete()


class ServerException(Exception):
    pass


def commit(repo, branch, changes, commit_message):
    elements = []
    for filepath, content in changes.items():
        log.debug(f"Creating file: {filepath}")
        blob = repo.create_git_blob(content, "utf-8")
        elements.append(
            github.InputGitTreeElement(
                path=filepath, mode="100644", type="blob", sha=blob.sha
            )
        )

    head_sha = repo.get_branch(branch).commit.sha
    base_tree = repo.get_git_tree(sha=head_sha)
    tree = repo.create_git_tree(elements, base_tree)
    parent = repo.get_git_commit(sha=head_sha)
    commit = repo.create_git_commit(commit_message, tree, [parent])

    return commit


def push(repo, branch, changes, commit_message="Adding test files"):
    try:
        ref = repo.get_branch(branch)
    except Exception:
        log.debug(f"Creating ref for branch: {branch}")
        ref = repo.create_git_ref(
            ref="refs/heads/" + branch,
            sha=repo.get_branch(repo.default_branch).commit.sha,
        )
        log.debug(f"Ref: {ref.ref}")

    commit_obj = commit(repo, branch, changes, commit_message)
    log.debug(f"Pushing commit ID: {commit_obj.sha}")
    ref.edit(sha=commit_obj.sha)

    return branch


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
