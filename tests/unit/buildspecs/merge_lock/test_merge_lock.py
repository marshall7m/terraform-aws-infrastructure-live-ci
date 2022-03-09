import pytest
import os
import subprocess
from github import Github
import uuid

@pytest.fixture(scope='module')
def gh():
    return Github(os.environ['GITHUB_TOKEN'])

@pytest.fixture(scope='module')
def repo(gh):
    repo = gh.get_user().create_repo(f'mut-terraform-aws-infrastructure-merge-lock-{uuid.uuid4()}', auto_init=True)
    os.environ['REPO_FULL_NAME'] = repo.full_name
    repo.create_file("init.txt", "test commit", "")['commit']
    repo.edit(default_branch='master')

    yield repo
    repo.delete()

@pytest.fixture()
def commit_id(repo):
    base = 'master'
    head = f'feature-{uuid.uuid4()}'

    base_commit = repo.get_branch(base)
    repo.create_git_ref(ref='refs/heads/' + head, sha=base_commit.commit.sha)

    commit = repo.create_file("new_file.txt", "test commit", "foo", branch=head)['commit'].sha
    repo.create_pull(title='test', body='test', base=base, head=head)

    yield commit

@pytest.mark.parametrize('merge_lock,expected_state', [('true', 'pending'), ('false', 'success')])
def test_status_check_pending(merge_lock, expected_state, commit_id, repo):
    os.environ["MERGE_LOCK"] = merge_lock
    os.environ["CODEBUILD_SOURCE_VERSION"] = commit_id

    subprocess.call('../merge_lock.bash', shell=True)
    assert repo.get_commit(commit_id).get_statuses()[0].state == expected_state