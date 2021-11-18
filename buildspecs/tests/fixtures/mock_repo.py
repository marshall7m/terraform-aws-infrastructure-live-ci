from pathlib import Path
import git
import pytest
import os
import subprocess
import logging
import shutil

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


# TODO: create class for fixtures to allow for access to global vars such as remote_url, session dir, function dirv via class instance?
# Example: repo_one = MockRepo(<git_url>) 
# repo_one.url
# repo_one.session_dir
# repo_one.function_dir

@pytest.fixture(scope="session", autouse=True)
def session_repo_dir(tmpdir_factory):
    dir = tmpdir_factory.mktemp('test-repo')
    git.Repo.clone_from('https://github.com/marshall7m/infrastructure-live-testing-template.git', dir)

    return dir

@pytest.fixture(scope="function", autouse=True)
def function_repo_dir(session_repo_dir, tmp_path):
    dir = tmp_path / 'test-repo'
    dir.mkdir()
    repo = git.Repo.clone_from(session_repo_dir, dir)

    return dir

def function_repo_remote(function_repo_dir, remote_fork=False):
    if remote_fork:
        gh = git.Github().get_user()
        testing_fork = gh.create_fork(repo)
        yield dir
        testing_fork.delete()
    else:
        # figure out how to add `dir` to local remote source (like git add remote local ./$dir)
        local = repo.remote('local')
        return dir

@pytest.fixture(scope="session", autouse=True)
def apply_session_mock_repo(session_repo_dir):
    os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR'] = f'{session_repo_dir}/tf-state'
    log.info('Applying mock repo Terraform resources')
    cmd = f'terragrunt run-all apply --terragrunt-working-dir {session_repo_dir}/directory_dependency/dev-account --terragrunt-non-interactive -auto-approve'.split(' ')
    log.debug(f'Command: {cmd}')
    yield subprocess.run(cmd, capture_output=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    log.info('Destroying mock repo Terraform resources')
    cmd = f'terragrunt run-all destroy --terragrunt-working-dir {session_repo_dir}/directory_dependency/dev-account --terragrunt-non-interactive -auto-approve'.split(' ')
    log.debug(f'Command: {cmd}')
    subprocess.run(cmd, capture_output=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

@pytest.fixture(scope="function", autouse=True)
def create_test_function_tf_state(tmp_dir):
    test_case_tf_state_parent_dir = tmp_dir.mkdir('tf-state')
    
    os.chdir(os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR'])
    for path in Path('.').rglob('*.tfstate'):
        new_path = os.path.join('../doo', path)
        os.makedirs(os.path.dirname(new_path))
        shutil.copy(path, new_path)

    # changing TESTING_LOCAL_PARENT_TF_STATE_DIR to test case tf-state dir to create persistant local tf-state
    # prevents loss of local tf-state when new github branches are created/checked out for mocking commits
    os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR'] = test_case_tf_state_parent_dir

def setup_terragrunt_branch_tracking():
    pass