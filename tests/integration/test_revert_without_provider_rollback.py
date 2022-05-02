from tests.integration import test_integration
import pytest
import uuid
import os
import logging
from pytest_dependency import depends
from tests.helpers.utils import dummy_tf_github_repo
import github

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

dummy_repo = f'dummy-repo-{uuid.uuid4()}'

class TestDeployPR(test_integration.Integration):
    '''
    Case covers a simple one node deployment that contains a new GitHub provider resource.
    '''
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve'
                },
                'pr_files_content': [dummy_tf_github_repo(dummy_repo)]
            }
        },
        'destroy_tf_resources_with_pr': True
    }   

class TestRevertPRWithoutProviderRollback(test_integration.Integration):
    '''
    Case will merge a PR that will revert the changes from the upstream case's PR. This case's associated
    create deploy stack Codebuild is expected to fail given that the reversion of the PR will remove not only the
    new Github resource block but also it's respective GitHub provider block that Terraform needs in order to destroy
    the GitHub resource.
    '''
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'revert_ref': TestDeployPR.case['head_ref'],
        'expect_failed_create_deploy_stack': True,
        'executions': {}
    }
    
    @pytest.mark.parametrize('cleanup_dummy_repo', [dummy_repo], indirect=True)
    def test_gh_resource_exists(self, cleanup_dummy_repo, gh, request, target_execution):
        depends(request, [f'{request.cls.__name__}::test_sf_execution_status[{request.node.callspec.id}]'])
        log.info(f'Assert GitHub repo was deleted: {dummy_repo}')
        try:
            gh.get_user().get_repo(cleanup_dummy_repo)
        except github.GithubException.UnknownObjectException:
            pass