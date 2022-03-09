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

def pytest_generate_tests(metafunc):
    if metafunc.config.getoption('skip_init'):
        metafunc.parametrize('mut', [True], scope='session', indirect=True)

    if metafunc.config.getoption('skip_apply'):
        metafunc.parametrize('mut_output', [True], scope='session', indirect=True)

    if 'scenario_param' in metafunc.fixturenames:
        metafunc.parametrize('scenario_param', [metafunc.cls.scenario], scope='module', indirect=True)

    if 'target_execution' in metafunc.fixturenames:
        rollback_execution_count = len([1 for scenario in metafunc.cls.scenario.values() if scenario['actions'].get('rollback_providers', None) != None])
        metafunc.parametrize('target_execution', list(range(0, len(metafunc.cls.scenario) + rollback_execution_count)), scope='class', indirect=True)

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

@pytest.fixture(scope="session")
def mut_output(mut, request):
    if getattr(request, 'param', False):
        log.info('Skip applying testing tf module')
    else:    
        log.info('Applying testing tf module')
        mut.apply(auto_approve=True)
    yield {k: v['value'] for k, v in mut.output().items()}

    # create flag for cleaning up testing module?
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

@pytest.fixture(scope='module')
def git_repo(tmp_path_factory):
    dir = str(tmp_path_factory.mktemp('scenario-repo-'))
    log.debug(f'Scenario repo dir: {dir}')

    yield git.Repo.clone_from(f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git', dir)