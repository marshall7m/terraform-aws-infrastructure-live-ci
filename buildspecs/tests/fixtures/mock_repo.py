import glob
import git
import pytest
import os
import subprocess
import logging
import shutil

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="session", autouse=True)
def repo_url():
    url = 'https://oauth2:{}@github.com/marshall7m/infrastructure-live-testing-template.git'.format(os.environ['GITHUB_TOKEN'])
    return url

@pytest.fixture(scope="session", autouse=True)
def session_repo_dir(tmp_path_factory, repo_url):
    dir = str(tmp_path_factory.mktemp('test-repo'))
    log.debug(f'Session repo dir: {dir}')

    git.Repo.clone_from(repo_url, dir)

    return dir

@pytest.fixture(scope="class", autouse=True)
def class_repo_dir(session_repo_dir, tmp_path_factory):
    dir = str(tmp_path_factory.mktemp('test-repo'))
    log.debug(f'Class repo dir: {dir}')

    git.Repo.clone_from(session_repo_dir, dir)

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
def create_test_function_tf_state(tmp_path):
    dir = tmp_path / 'tf-state'
    dir.mkdir()
    
    dir = str(dir)
    log.debug(f'Function tf-state dir: {dir}')

    src = os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR']
    for path in glob.glob(os.path.join(src, '**', '*.tfstate'), recursive=True):
        new_path = os.path.join(dir, os.path.relpath(path, src))
        os.makedirs(os.path.dirname(new_path))
        shutil.copy(path, new_path)

    # changing TESTING_LOCAL_PARENT_TF_STATE_DIR to test case tf-state dir to create persistant local tf-state
    # prevents loss of local tf-state when new github branches are created/checked out for mocking commits
    os.environ['TESTING_LOCAL_PARENT_TF_STATE_DIR'] = str(dir)

def setup_terragrunt_branch_tracking():
    pass