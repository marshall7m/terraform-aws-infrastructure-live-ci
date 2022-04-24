import pytest
import os
import random
import string
import logging
import git
from unittest.mock import patch
from unittest.mock import mock_open
from tests.helpers.utils import dummy_tf_output, dummy_tf_provider_resource, insert_records, terra_version

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

tf_versions = [
    pytest.param('latest'),
    pytest.param('1.0.0', marks=pytest.mark.skip()), 
    pytest.param('0.15.0', marks=pytest.mark.skip()), 
    pytest.param('0.14.0', marks=pytest.mark.skip())
]
@pytest.fixture(params=tf_versions, ids=[f'tf_{v}' for v in tf_versions])
def terraform_version(request):
    '''Terraform version that will be installed and used'''
    terra_version('terraform', request.param, overwrite=True)
    return request.param

tg_versions = [
    pytest.param('0.36.7'),
    pytest.param('0.36.0', marks=pytest.mark.skip()), 
    pytest.param('0.35.0', marks=pytest.mark.skip()), 
    pytest.param('0.34.0', marks=pytest.mark.skip())
]
@pytest.fixture(params=tg_versions, ids=[f'tg_{v}' for v in tg_versions])
def terragrunt_version(request):
    '''Terragrunt version that will be installed and used'''
    terra_version('terragrunt', request.param, overwrite=True)
    return request.param

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
    ),
    pytest.param(
        {'directory_dependency/dev-account/us-west-2/env-one/doo': [dummy_tf_provider_resource()]},
        [
            {
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                'cfg_deps': [],
                'new_providers': ['registry.terraform.io/hashicorp/null']
            }
        ],
        id='no_deps_new_provider'
    )
    pytest.param(
        {'directory_dependency/dev-account/global': [dummy_tf_output()]},
        [
            {
                'cfg_path': 'directory_dependency/dev-account/global',
                'cfg_deps': [],
                'new_providers': []
            },
            {
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                'cfg_deps': ['directory_dependency/dev-account/global'],
                'new_providers': []
            },
            {
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/baz',
                'cfg_deps': ['directory_dependency/dev-account/global'],
                'new_providers': []
            },
            {
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/bar',
                'cfg_deps': ['directory_dependency/dev-account/us-west-2/env-one/baz', 'directory_dependency/dev-account/global'],
                'new_providers': []
            },
            {
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/foo',
                'cfg_deps': ['directory_dependency/dev-account/us-west-2/env-one/bar'],
                'new_providers': []
            }
        ],
        id='multi_deps'
    )
], indirect=['repo_changes'])
@patch.dict(os.environ, {'TG_BACKEND': 'local'})
@pytest.mark.usefixtures('aws_credentials', 'terraform_version', 'terragrunt_version')
def test_create_stack(git_repo, repo_changes, expected_stack):
    '''
    Ensures that create_stack() parses the Terragrunt command output correctly, 
    filters out any directories that don't have changes and detects any new 
    providers introduced within the configurations
    '''
    from buildspecs.create_deploy_stack.create_deploy_stack import CreateStack

    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse('--show-toplevel')
    os.chdir(git_root)

    log.debug('Running create_stack()')
    create_stack = CreateStack()

    # for sake of testing, using just one account directory
    stack = create_stack.create_stack('directory_dependency/dev-account', git_root)
    log.debug(f'Stack:\n{stack}')
    #convert list of dict to list of list of tuples since dict are not ordered
    assert sorted(sorted(cfg.items()) for cfg in stack) == sorted(sorted(cfg.items()) for cfg in expected_stack)

#mock codebuild env vars
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
    'TG_BACKEND': 'local'
})
#mock aws boto3 clients
@patch('buildspecs.create_deploy_stack.create_deploy_stack.CreateStack.set_aws_env_vars')
@patch('buildspecs.create_deploy_stack.create_deploy_stack.ssm')
@patch('buildspecs.create_deploy_stack.create_deploy_stack.lb')
@patch('aurora_data_api.connect')
@pytest.mark.usefixtures('aws_credentials')
@pytest.mark.parametrize('repo_changes,accounts,expected_failure', [
    pytest.param(
        {'directory_dependency/dev-account/global': [dummy_tf_output()]},
        [('directory_dependency/dev-account', 'mock-plan-role-arn')],
        False,
        id='no_deps'
    ),
    pytest.param(
        {'directory_dependency/dev-account/global': [dummy_tf_output()]},
        [('directory_dependency/invalid-account', 'mock-plan-role-arn')],
        True,
        id='invalid_account_path'
    ),
    pytest.param(
        {
            'directory_dependency/dev-account/global': [dummy_tf_output(name="1_invalid_name")],
            'directory_dependency/shared-services-account/global': [dummy_tf_output()]
        },
        [
            ('directory_dependency/dev-account', 'mock-plan-role-arn'),
            ('directory_dependency/shared-services-account', 'mock-plan-role-arn')
        ],
        True,
        id='tg_error'
    )
], indirect=['repo_changes'])

def test_main(mock_conn, mock_lambda, mock_ssm, mock_set_aws_env_vars, repo_changes, accounts, expected_failure, git_repo):
    '''Ensures main() handles errors properly from top level'''
    from buildspecs.create_deploy_stack.create_deploy_stack import CreateStack

    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse('--show-toplevel')
    os.chdir(git_root)

    # get nested aurora.connect() context manager mock
    mock_conn_context = mock_conn.return_value.__enter__.return_value
    # get nested conn.cursor() context manager mock
    mock_cur = mock_conn_context.cursor.return_value.__enter__.return_value
    # mock retrieval of [(account_path, plan_role_arn)] from account dim
    mock_cur.fetchall.return_value = accounts
    
    create_stack = CreateStack()
    try:
        create_stack.main()
    except Exception as e:
        log.debug(e)

    if expected_failure:
        log.info('Assert execution record creation was rolled back')
        mock_conn_context.rollback.assert_called_once()

        log.info('Assert merge lock value was reset')
        mock_ssm.put_parameter.assert_called_with(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value='none', Type='String', Overwrite=True)

        log.info('Assert Lambda Function was not invoked')
        mock_lambda.invoke.assert_not_called()
    else:
        log.info('Assert execution record creation was not rolled back')
        mock_cur.rollback.assert_not_called()

        log.info('Assert merge lock value was set')
        mock_ssm.put_parameter.assert_called_with(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value=os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[1], Type='String', Overwrite=True)

        log.info('Assert Lambda Function was invoked')
        mock_lambda.invoke.assert_called_once()
