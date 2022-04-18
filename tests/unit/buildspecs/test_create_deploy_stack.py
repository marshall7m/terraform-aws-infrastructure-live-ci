from distutils.command.check import check
import pytest
import os
import random
import string
import logging
import git
from unittest.mock import patch
from buildspecs.create_deploy_stack.create_deploy_stack import CreateStack
from tests.helpers.utils import dummy_tf_output, insert_records, tf_version

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope='module', autouse=True)
def account_dim(conn, cur):
    results = insert_records(conn, 'account_dim', [
        {
            'account_name': 'dev',
            'account_path': 'directory_dependency/dev-account',
            'account_deps': ['shared-services'],
        },
        {
            'account_name': 'shared-services',
            'account_path': 'directory_dependency/shared-account',
            'account_deps': []
        }
    ])

    yield results

    cur.execute('TRUNCATE account_dim')

@pytest.fixture(scope='module')
def base_git_repo(tmp_path_factory):
    root_dir = str(tmp_path_factory.mktemp('test-create-deploy-stack-'))
    yield git.Repo.clone_from(f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/marshall7m/infrastructure-live-testing-template.git', root_dir)

@pytest.fixture(scope='function')
def git_repo(tmp_path_factory, base_git_repo):
    param_git_dir = str(tmp_path_factory.mktemp('test-create-deploy-stack-param-'))
    yield git.Repo.clone_from(str(base_git_repo.git.rev_parse('--show-toplevel')), param_git_dir)
    
@pytest.fixture(scope='function')
def repo_changes(request, git_repo):
    for dir, contents in request.param.items():
        for content in contents:
            abs_path = str(git_repo.git.rev_parse('--show-toplevel')) + '/' + dir + '/' + ''.join(random.choice(string.ascii_lowercase) for _ in range(8)) + '.tf'
            
            log.debug(f'Creating file: {abs_path}')
            with open(abs_path, 'w') as text_file:
                text_file.write(content)

    return request.param

@patch.dict(os.environ, {
    'CODEBUILD_INITIATOR': 'GitHub-Hookshot/test',
    'CODEBUILD_WEBHOOK_TRIGGER': 'pr/1',
    'CODEBUILD_RESOLVED_SOURCE_VERSION': 'test-commit',
    'CODEBUILD_WEBHOOK_BASE_REF': 'master',
    'CODEBUILD_WEBHOOK_HEAD_REF': 'test-feature',
    'METADB_CLUSTER_ARN': 'mock',
    'METADB_SECRET_ARN': 'mock',
    'METADB_NAME': 'mock',
    'STATE_MACHINE_ARN': 'mock',
    'GITHUB_MERGE_LOCK_SSM_KEY': 'mock-ssm-key',
    'TRIGGER_SF_FUNCTION_NAME': 'mock-lambda',
    'TG_BACKEND': 'local',
    'TERRAGRUNT_LOG_LEVEL': 'debug'
})
@pytest.mark.usefixtures('aws_credentials')
@pytest.mark.parametrize('repo_changes,expected_stack', [
    pytest.param(
        {'directory_dependency/dev-account/us-west-2/env-one/doo': [dummy_tf_output()]},
        [
            {
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                'cfg_deps': [],
                'new_providers': []
            }
        ],
        id='no_deps'
    )
], indirect=['repo_changes'])

def test__create_stack(git_repo, repo_changes, expected_stack):
    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse('--show-toplevel')
    os.chdir(git_root)
    tf_version('latest')

    log.debug('Running create_stack()')
    create_stack = CreateStack()

    stack = create_stack.create_stack('directory_dependency/dev-account', git_root)
    log.debug(f'Stack:\n{stack}')
    assert all(cfg in expected_stack for cfg in stack)

@pytest.mark.skip(msg='Not implemented')
@patch('buildspecs.create_deploy_stack.create_stack')
def test__update_executions_with_new_deploy_stack(mock_stack, stack):
    log.debug("Changing to the test repo's root directory")
    os.chdir(git_repo.git.rev_parse('--show-toplevel'))

    log.debug('Running _update_executions_with_new_deploy_stack()')
    mock_stack.return_value = stack

    log.info('Assert records were created')

@patch('buildspecs.create_deploy_stack.ssm')
@patch('buildspecs.create_deploy_stack.lb')
@pytest.mark.skip(msg='Not implemented')
def test_main(mock_lambda, mock_ssm):
    log.info('Assert merge lock value was set')
    assert mock_ssm.put_parameter.called_once == True

    log.info('Assert Lambda Function was invoked')
    assert mock_lambda.invoke.called_once == True
