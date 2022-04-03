from tests.integration import test_integration
import pytest
import uuid
import os
import logging
from pytest_dependency import depends

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

dummy_repo = f'dummy-repo-{uuid.uuid4()}'

test_gh_resource = f"""
terraform {{
  required_providers {{
    github = {{
      source  = "integrations/github"
      version = "4.9.3"
    }}
  }}
}}
provider "aws" {{}}

data "aws_ssm_parameter" "github_token" {{
    name = "admin-github-token"
}}

provider "github" {{
    owner = "marshall7m"
    token = data.aws_ssm_parameter.github_token.value
}}

resource "github_repository" "dummy" {{
  name        = "{dummy_repo}"
  visibility  = "public"
}}
"""

@pytest.fixture(scope='module', autouse=True)
def cleanup_dummy_repo(gh):
    yield None
    log.info('Deleting dummy GitHub repo')
    gh.get_user().get_repo(dummy_repo).delete()

class TestDeployPR(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve'
                },
                'new_resources': ['github_branch.this'],
                'pr_files_content': [test_gh_resource]
            }
        }
    }

class TestRevertPRWithoutProviderRollback(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'revert_ref': TestDeployPR.case['head_ref'],
        'expect_failed_create_deploy_stack': True,
        'executions': {}
    }
    
    def test_gh_resource_exists(self, gh, request, target_execution):
        depends(request, [f'{request.cls.__name__}::test_sf_execution_status[{request.node.callspec.id}]'])
        log.info(f'Assert GitHub repo still exists: {dummy_repo}')
        print(gh.get_user().get_repo(dummy_repo))