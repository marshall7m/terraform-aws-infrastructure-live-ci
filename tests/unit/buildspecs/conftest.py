import pytest
import os
import random
import string
import logging
import git
from tests.helpers.utils import insert_records

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope='module', autouse=True)
def account_dim(conn, cur):
    '''Creates account records within local db'''
    results = insert_records(conn, 'account_dim', [
        {
            'account_name': 'dev',
            'account_path': 'directory_dependency/dev-account',
            'account_deps': ['shared-services'],
        },
        {
            'account_name': 'shared-services',
            'account_path': 'directory_dependency/shared-services-account',
            'account_deps': []
        }
    ])

    yield results

    cur.execute('TRUNCATE account_dim')

@pytest.fixture(scope='module')
def base_git_repo(tmp_path_factory):
    '''Clones template infrastructure-live repo from GitHub into local tmp dir'''
    root_dir = str(tmp_path_factory.mktemp('test-create-deploy-stack-'))
    yield git.Repo.clone_from(f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/marshall7m/infrastructure-live-testing-template.git', root_dir)

@pytest.fixture(scope='function')
def git_repo(tmp_path_factory, base_git_repo):
    '''Clones template infrastructure-live repo from tmp dir to another tmp dir for each test function. Reason for fixture is to reduce amount of remote clones needed for testing'''
    param_git_dir = str(tmp_path_factory.mktemp('test-create-deploy-stack-param-'))
    yield git.Repo.clone_from(str(base_git_repo.git.rev_parse('--show-toplevel')), param_git_dir)
    
@pytest.fixture(scope='function')
def repo_changes(request, git_repo):
    '''
    Creates Terraform files within the test's version of the local repo
    
    Arguments:
    request.param: Map keys consisting of directory paths that are relative to the root directory of the repo and 
        list values containing the content to write to the directory path with each representing a new file
    '''
    for dir, contents in request.param.items():
        for content in contents:
            abs_path = str(git_repo.git.rev_parse('--show-toplevel')) + '/' + dir + '/' + ''.join(random.choice(string.ascii_lowercase) for _ in range(8)) + '.tf'
            
            log.debug(f'Creating file: {abs_path}')
            with open(abs_path, 'w') as text_file:
                text_file.write(content)

    return request.param