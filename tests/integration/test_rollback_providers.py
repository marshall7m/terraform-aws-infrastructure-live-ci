from tests.integration import test_integration
import uuid

class TestSucceededRollbackProvider(test_integration.Integration):
    test_null_resource = """
    provider "null" {}

    resource "null_resource" "a" {}
    """
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'approve'
                },
                'new_resources': ['null_resource.a'],
                'pr_files_content': [test_null_resource],
                'new_providers': ['hashicorp/null']
            }
        }
    }

class TestRejectedRollbackProvider(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'reject'
                },
                'new_resources': ['null_resource.b'],
                'pr_files_content': ['resource "null_resource" "b" {{}}'],
                'new_providers': ['hashicorp/null']
            }
        }
    }    

class TestRevertNewProviderPRWithoutRollback(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'revert_ref': TestRejectedRollbackProvider.case['head_ref'],
        'expect_failed_trigger_sf': True,
        'executions': {}
    }