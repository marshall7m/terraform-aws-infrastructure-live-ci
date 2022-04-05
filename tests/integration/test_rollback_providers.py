from tests.integration import test_integration
from tests.integration.helpers import dummy_tf_github_repo, dummy_tf_output
import pytest
import uuid
import os
import github
import logging
from pytest_dependency import depends

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

dummy_repo = f'dummy-repo-{uuid.uuid4()}'

class TestDeployPR(test_integration.Integration):
    '''
    Case covers a simple 2 node deployment with each having no account-level dependencies and
    the second deployment having a dependency on the first one.
    The first deployment will be approved while the second deployment will be rejected.
    The rejection of the second deployment will cause the first deployment to have a
    rollback new provider resources deployment. See <TODO: Add reference to explaination of rollback new provider resources process>
    for more information on how the rollback deployment works.
    The rollback deployment will be approved which will allow the downstream revert PR to be able to freely run deployments
    without having to have the GitHub provider block introduced in this PR.
    '''
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/bar': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'approve'
                },
                'pr_files_content': [dummy_tf_github_repo(), dummy_tf_output()]
            },
            'directory_dependency/dev-account/us-west-2/env-one/foo': {
                'actions': {
                    'deploy': 'reject'
                },
                'pr_files_content': [dummy_tf_output()]
            }
        }
    }

class TestRevertPR(test_integration.Integration):
    '''
    TODO
    '''
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'revert_ref': TestDeployPR.case['head_ref'],
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/bar': {
                'actions': {
                    'deploy': 'approve'
                }
            },
            'directory_dependency/dev-account/us-west-2/env-one/foo': {
                'actions': {
                    'deploy': 'approve'
                }
            }
        }
    }
    
    @pytest.mark.parametrize('cleanup_dummy_repo', [dummy_repo], indirect=True)
    def test_gh_resource_exists(self, cleanup_dummy_repo, gh, request, target_execution):
        '''TODO'''
        depends(request, [f'{request.cls.__name__}::test_sf_execution_status[{request.node.callspec.id}]'])
        log.info(f'Assert GitHub repo was deleted: {dummy_repo}')
        try:
            gh.get_user().get_repo(cleanup_dummy_repo)
        except github.GithubException.UnknownObjectException:
            pass