import pytest
import psycopg2
import os
import tftest
import boto3
import github
import subprocess
import logging
import sys
import aurora_data_api

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def pytest_addoption(parser):
    #TODO: Add --skip-tfenv and transfer logic from --skip-init
    parser.addoption("--skip-init", action="store_true", help="skips initing tf module")
    parser.addoption("--skip-apply", action="store_true", help="skips applying tf module")

@pytest.fixture(scope="session")
def mut(request):
    tf_dir = os.path.dirname(os.path.realpath(__file__))

    if 'GITHUB_TOKEN' not in os.environ:
        log.error('$GITHUB_TOKEN env var is not set -- required to setup Github resources')
        sys.exit(1)

    log.info('Initializing testing module')
    tf = tftest.TerraformTest(tf_dir)

    if getattr(request, 'param', False):
        log.info('Skip scanning for tf version')
        log.info('Skip initing testing tf module')
    else:
        log.info('Scanning tf config for minimum tf version')
        out = subprocess.run('tfenv install min-required && tfenv use min-required', 
            cwd=tf_dir, shell=True, capture_output=True, check=True, text=True
        )

        log.debug(f'tfenv out: {out.stdout}')
        log.info('Initing testing tf module')
        tf.init()

    yield tf

@pytest.fixture(scope="session")
def mut_plan(mut, request):
    log.info('Getting testing tf plan')
    yield mut.plan(output=True)

@pytest.fixture(scope="session")
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
        secret_arn=mut_output['metadb_secret_manager_arn'],
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
def merge_pr(repo, pr, merge_lock_status):
    log.info('Merging PR')
    yield repo.merge(os.environ['BASE_REF'], os.environ['HEAD_REF'])