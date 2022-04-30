import pytest
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
from tests.integration.test_integration import Integration
from pprint import pformat
from tests.helpers.utils import terra_version

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def pytest_addoption(parser):

    parser.addoption("--tf-init", action="store_true", help="inits testing Terraform module")
    parser.addoption("--tf-apply", action="store_true", help="applys testing Terraform module")
    parser.addoption("--tf-destroy", action="store_true", help="destroys testing Terraform module")

    parser.addoption("--skip-truncate", action="store_true", help="skips truncating execution table")

def pytest_generate_tests(metafunc):
    if metafunc.config.getoption('tf_init'):
        metafunc.parametrize('mut', [True], scope='session', ids=['tf_init'], indirect=True)

    if metafunc.config.getoption('tf_apply'):
        metafunc.parametrize('mut_output', [True], scope='session', ids=['tf_apply'], indirect=True)
    
    if metafunc.config.getoption('tf_destroy'):
        metafunc.parametrize('mut_output', [True], scope='session', ids=['tf_destroy'], indirect=True)

    if metafunc.config.getoption('skip_truncate'):
        metafunc.parametrize('truncate_executions', [True], scope='session', ids=['skip_truncate'], indirect=True)

    #TODO: Since only one case per cls, see if it's possible to get class case within request objected via request.cls.case to remove need to use parametrization
    if hasattr(metafunc.cls, 'case'):
        if 'target_execution' in metafunc.fixturenames:
            rollback_execution_count = len([1 for scenario in metafunc.cls.case['executions'].values() if scenario.get('actions', {}).get('rollback_providers', None) != None])
            metafunc.parametrize('target_execution', list(range(0, len(metafunc.cls.case['executions']) + rollback_execution_count)), scope='class', indirect=True)

@pytest.fixture(scope="session")
def mut(request):
    terra_version('terraform', '1.0.2', overwrite=True)

    tf_dir = os.path.dirname(os.path.realpath(__file__))

    if 'GITHUB_TOKEN' not in os.environ:
        log.error('$GITHUB_TOKEN env var is not set -- required to setup Github resources')
        sys.exit(1)

    log.info('Initializing testing module')
    tf = tftest.TerraformTest(tf_dir)

    if getattr(request, 'param', False):
        log.info('Initing testing tf module')
        tf.init()
    else:
        log.info('Skip initing testing tf module')

    yield tf
    
@pytest.fixture(scope="session")
def mut_plan(mut, request):
    log.info('Getting testing tf plan')
    yield mut.plan(output=True)

@pytest.fixture(scope="session")
def mut_output(mut, request):
    if getattr(getattr(request, 'param', False), 'tf_apply', False):
        log.info('Applying testing tf module')
        mut.apply(auto_approve=True)
    else:    
        log.info('Skip applying testing tf module')
    
    yield {k: v['value'] for k, v in mut.output().items()}

    if getattr(getattr(request, 'param', False), 'tf_destroy', False):
        log.info('Destroying testing tf module')
        mut.apply(destroy=True)
    else:    
        log.info('Skip destroying testing tf module')

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

@pytest.fixture(scope='module')
def gh():
    return github.Github(os.environ['GITHUB_TOKEN'], retry=3)

@pytest.fixture(scope='module')
def repo(gh, mut_output):
    repo = gh.get_user().get_repo(mut_output['repo_name'])
    os.environ['REPO_FULL_NAME'] = repo.full_name
    # repo.edit(default_branch='master')

    return repo

@pytest.fixture(scope='module')
def git_repo(tmp_path_factory):
    dir = str(tmp_path_factory.mktemp('scenario-repo-'))
    log.debug(f'Scenario repo dir: {dir}')

    yield git.Repo.clone_from(f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git', dir)

@pytest.fixture(scope='module')
def merge_pr(repo, git_repo):
    
    merge_commits = {}

    def _merge(base_ref=None, head_ref=None):
        if base_ref != None and head_ref != None:
            log.info('Merging PR')
            merge_commits[head_ref] = repo.merge(base_ref, head_ref)

        return merge_commits

    yield _merge
    
    log.info(f'Removing PR changes from branch: {git_repo.git.branch("--show-current")}')

    log.debug('Pulling remote changes')
    git_repo.git.reset('--hard')
    git_repo.git.pull()

    log.debug('Removing admin enforcement from branch protection to allow revert pushes to trunk branch')
    branch = repo.get_branch(branch="master")
    branch.remove_admin_enforcement()
    
    log.debug('Removing required status checks')
    status_checks = branch.get_required_status_checks().contexts
    branch.edit_required_status_checks(contexts=[])

    for ref, commit in reversed(merge_commits.items()):
        log.debug(f'Merge Commit ID: {commit.sha}')
        try:
            git_repo.git.revert('-m', '1', '--no-commit', str(commit.sha))
            git_repo.git.commit('-m', f'Revert changes from PR: {ref} within fixture teardown')
            git_repo.git.push('origin', '--force')
        except Exception as e:
            raise e
        finally:
            log.debug('Adding admin enforcement back')
            branch.set_admin_enforcement()

            log.debug('Adding required status checks back')
            branch.edit_required_status_checks(contexts=status_checks)

@pytest.fixture(scope='module', autouse=True)
def truncate_executions(request, mut_output):
    #table setup is within tf module
    #yielding none to define truncation as pytest teardown logic
    yield None
    if getattr(request, 'param', False):
        log.info('Skip truncating execution table')
    else:    
        log.info('Truncating executions table')
        with aurora_data_api.connect(
            aurora_cluster_arn=mut_output['metadb_arn'],
            secret_arn=mut_output['metadb_secret_manager_master_arn'],
            database=mut_output['metadb_name'],
            #recommended for DDL statements
            continue_after_timeout=True
        ) as conn:
            with conn.cursor() as cur:
                cur.execute("TRUNCATE executions")

@pytest.fixture(scope='module', autouse=True)
def reset_merge_lock_ssm_value(request, mut_output):
    ssm = boto3.client('ssm')
    log.info(f'Resetting merge lock SSM value for module: {request.fspath}')
    yield ssm.put_parameter(Name=mut_output['merge_lock_ssm_key'], Value='none', Type='String', Overwrite=True)

@pytest.fixture(scope='module', autouse=True)
def abort_hanging_sf_executions(mut_output):
    yield None

    sf = boto3.client('stepfunctions')

    log.info('Stopping step function execution if left hanging')
    execution_arns = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'], statusFilter='RUNNING')['executions']]

    for arn in execution_arns:
        log.debug(f'ARN: {arn}')

        sf.stop_execution(
            executionArn=arn,
            error='IntegrationTestsError',
            cause='Failed integrations tests prevented execution from finishing'
        )

@pytest.fixture(scope='module')
def cleanup_dummy_repo(gh, request):
    yield request.param
    try:
        log.info(f'Deleting dummy GitHub repo: {request.param}')
        gh.get_user().get_repo(request.param).delete()
    except github.GithubException.UnknownObjectException:
        log.info('GitHub repo does not exist')