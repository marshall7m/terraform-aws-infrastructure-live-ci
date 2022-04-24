from unittest import mock
import pytest
import os
import logging
import subprocess
from unittest.mock import patch
from tests.helpers.utils import dummy_tf_provider_resource, insert_records, terra_version
from buildspecs.terra_run import update_new_resources

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

@pytest.fixture(autouse=True)
def git_repo_cwd(git_repo):
    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse('--show-toplevel')
    os.chdir(git_root)
    return git_root

def tg_apply(dirs):
    for dir in dirs:
        cmd = f'terragrunt apply --terragrunt-working-dir {dir} -auto-approve'
        _ = subprocess.run(cmd.split(' '), check=True)

@patch.dict(os.environ, {'TG_BACKEND': 'local', 'NEW_PROVIDERS': '[test-provider]', 'IS_ROLLBACK': 'false'})
@pytest.mark.usefixtures('terraform_version', 'terragrunt_version')
@pytest.mark.parametrize('repo_changes,new_providers,expected', [
    pytest.param(
        {'directory_dependency/dev-account/us-west-2/env-one/doo': [dummy_tf_provider_resource()]},
        ['registry.terraform.io/hashicorp/null'],
        ['null_resource.this'],
        id='new_resource_exists'
    ),
    pytest.param(
        {'directory_dependency/dev-account/us-west-2/env-one/doo': []},
        ['registry.terraform.io/hashicorp/null'],
        [],
        id='new_resource_not_exists'
    )
], indirect=['repo_changes'])
def test_get_new_provider_resources(repo_changes, new_providers, expected):
    target_path = list(repo_changes.keys())[0]
    tg_apply([target_path])
    actual = update_new_resources.get_new_provider_resources(target_path, new_providers)
    
    assert actual == expected

@patch.dict(os.environ, {
    'METADB_CLUSTER_ARN': 'mock',
    'METADB_SECRET_ARN': 'mock',
    'METADB_NAME': 'mock',
    'TG_BACKEND': 'local',
    'CFG_PATH': 'test/dir',
    'NEW_PROVIDERS': '[test-provider]',
    'IS_ROLLBACK': 'false'
})
@patch('buildspecs.terra_run.update_new_resources.get_new_provider_resources')
@pytest.mark.usefixtures('mock_conn', 'aws_credentials')
@pytest.mark.parametrize('resources', [
    pytest.param(['test.this'], id='one_resource'),
    pytest.param(['test.this', 'test.that'], id='multiple_resources'),
    pytest.param([], id='no_resources')
])
def test_main(mock_get_new_provider_resources, conn, resources):
    os.environ['EXECUTION_ID'] = 'test-id'
    insert_records(conn, 'executions', [{'execution_id': os.environ['EXECUTION_ID']}], enable_defaults=True)

    mock_get_new_provider_resources.return_value = resources

    update_new_resources.main()



