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
from tests.integration.test_integration import Integration
from pprint import pformat


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def pytest_addoption(parser):
    #TODO: Add --skip-tfenv and transfer logic from --skip-init
    parser.addoption("--skip-init", action="store_true", help="skips initing tf module")
    parser.addoption("--skip-apply", action="store_true", help="skips applying tf module")
    parser.addoption("--skip-truncate", action="store_true", help="skips truncating execution table")

def pytest_generate_tests(metafunc):
    if metafunc.config.getoption('skip_init'):
        metafunc.parametrize('mut', [True], scope='session', ids=['skip_init'], indirect=True)

    if metafunc.config.getoption('skip_apply'):
        metafunc.parametrize('mut_output', [True], scope='session', ids=['skip_apply'], indirect=True)

    if metafunc.config.getoption('skip_truncate'):
        metafunc.parametrize('truncate_executions', [True], scope='session', ids=['skip_truncate'], indirect=True)

    if hasattr(metafunc.cls, 'case'):

        if 'case_param' in metafunc.fixturenames:
            metafunc.parametrize('case_param', [metafunc.cls.case], scope='class', ids=['case'], indirect=True)

        if 'target_execution' in metafunc.fixturenames:
            rollback_execution_count = len([1 for scenario in metafunc.cls.case['executions'].values() if scenario.get('actions', {}).get('rollback_providers', None) != None])
            metafunc.parametrize('target_execution', list(range(0, len(metafunc.cls.case['executions']) + rollback_execution_count)), scope='class', indirect=True)

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

    for ref, commit in reversed(merge_commits.items()):
        log.debug(f'Merge Commit ID: {commit.sha}')
        try:
            git_repo.git.revert('-m', '1', '--no-commit', str(commit.sha))
            git_repo.git.commit('-m', f'Revert changes from PR: {ref} within fixture teardown')
            git_repo.git.push('origin')
        except Exception as e:
            print(e)

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
def abort_hanging_sf_executions(sf, mut_output):
    yield None

    log.info('Stopping step function execution if left hanging')
    execution_arns = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'], statusFilter='RUNNING')['executions']]

    for arn in execution_arns:
        log.debug(f'ARN: {arn}')

        sf.stop_execution(
            executionArn=arn,
            error='IntegrationTestsError',
            cause='Failed integrations tests prevented execution from finishing'
        )

@pytest.fixture(scope='module', autouse=True)
def destroy_scenario_tf_resources(cb, conn, mut_output):

    yield None
    log.info('Destroying Terraform provisioned resources from test repository')

    with conn.cursor() as cur:
        cur.execute(f"""
        SELECT account_name, account_path, deploy_role_arn
        FROM account_dim 
        """
        )

        accounts = []
        for result in cur.fetchall():
            record = {}
            for i, description in enumerate(cur.description):
                record[description.name] = result[i]
            accounts.append(record)
    conn.commit()
        
    log.debug(f'Accounts:\n{pformat(accounts)}')

    ids = []
    log.info("Starting account-level terraform destroy builds")
    for account in accounts:
        log.debug(f'Account Name: {account["account_name"]}')

        response = cb.start_build(
            projectName=mut_output['codebuild_terra_run_name'],
            environmentVariablesOverride=[
                {
                    'name': 'TG_COMMAND',
                    'type': 'PLAINTEXT',
                    'value': f'terragrunt run-all destroy --terragrunt-working-dir {account["account_path"]} -auto-approve'
                },
                {
                    'name': 'ROLE_ARN',
                    'type': 'PLAINTEXT',
                    'value': account['deploy_role_arn']
                }
            ]
        )

        ids.append(response['build']['id'])
    
    log.info('Waiting on destroy builds to finish')
    statuses = Integration().get_build_status(cb, mut_output['codebuild_terra_run_name'], ids=ids)

    log.info(f'Finished Statuses:\n{statuses}')
