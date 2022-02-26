import pytest
import psycopg2
import os
import tftest
import boto3
import github
import subprocess
import logging
import sys
import shutil
import aurora_data_api
import git

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def pytest_addoption(parser):
    #TODO: Add --skip-tfenv and transfer logic from --skip-init
    parser.addoption("--skip-init", action="store_true", help="skips initing tf module")
    parser.addoption("--skip-apply", action="store_true", help="skips applying tf module")

@pytest.fixture(scope="session", autouse=True)
def tf_version():
    tf_dir = os.path.dirname(os.path.realpath(__file__))
    version = subprocess.run('terraform --version', shell=True, capture_output=True, text=True)
    if version.returncode == 0:
        log.info('Terraform found in $PATH -- skip scanning for tf version')
        log.info(f'Terraform Version: {version.stdout}')
    else:
        log.info('Scanning tf config for minimum tf version')
        out = subprocess.run('tfenv install min-required && tfenv use min-required', 
            cwd=tf_dir, shell=True, capture_output=True, check=True, text=True
        )
        log.debug(f'tfenv out: {out.stdout}')

@pytest.fixture(scope="session")
def mut(request, tf_version):
    tf_dir = os.path.dirname(os.path.realpath(__file__))

    if 'GITHUB_TOKEN' not in os.environ:
        log.error('$GITHUB_TOKEN env var is not set -- required to setup Github resources')
        sys.exit(1)

    log.info('Initializing testing module')
    tf = tftest.TerraformTest(tf_dir)

    if getattr(request, 'param', False):
        log.info('Skip initing testing tf module')
    else:
        log.info('Initing testing tf module')
        tf.init()

    yield tf
    
@pytest.fixture(scope="session")
def mut_plan(mut, request):
    log.info('Getting testing tf plan')
    yield mut.plan(output=True)

@pytest.fixture(scope="session", autouse=True)
def mut_output(mut, request):
    if getattr(request, 'param', False):
        log.info('Skip applying testing tf module')
    else:    
        log.info('Applying testing tf module')
        mut.apply(auto_approve=True)
    yield {k: v['value'] for k, v in mut.output().items()}
    # tf.destroy(auto_approve=True)

@pytest.fixture(scope="session")
def conn(mut_output):
    conn = aurora_data_api.connect(
        aurora_cluster_arn=mut_output['metadb_arn'],
        secret_arn=mut_output['metadb_secret_manager_master_arn'],
        database=mut_output['metadb_name']
    )

    yield conn
    conn.close()

@pytest.fixture(scope="session")
def cur(conn):
    cur = conn.cursor()
    yield cur
    cur.close()

@pytest.fixture(scope="session")
def cb():
    return boto3.client('codebuild')

@pytest.fixture(scope='session')
def sf():
    return boto3.client('stepfunctions')

@pytest.fixture(scope='module')
def gh():
    return github.Github(os.environ['GITHUB_TOKEN'])

@pytest.fixture(scope='module')
def repo(gh, mut_output):
    repo = gh.get_user().get_repo(mut_output['repo_name'])
    os.environ['REPO_FULL_NAME'] = repo.full_name
    repo.edit(default_branch='master')

    return repo

@pytest.fixture(scope='class')
def git_repo(tmp_path_factory):
    dir = str(tmp_path_factory.mktemp('scenario-repo-'))
    log.debug(f'Scenario repo dir: {dir}')

    yield git.Repo.clone_from(f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git', dir)
    
@pytest.fixture(scope='class')
def merge_pr(repo, pr, merge_lock_status, git_repo):
    log.info('Merging PR')
    base_commit_id = repo.get_branch(os.environ['BASE_REF']).commit.sha
    merge_commit = repo.merge(os.environ['BASE_REF'], os.environ['HEAD_REF'])
    yield merge_commit

    log.info('Removing PR changes')

    log.info(f'Reverting to commit ID: {base_commit_id}')
    git_repo.git.reset('--hard')
    git_repo.git.pull()
    git_repo.git.revert('-m', '1', str(merge_commit.sha), no_edit=True)
    git_repo.git.push('origin')