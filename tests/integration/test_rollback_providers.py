from tests.integration import test_integration
import uuid

test_null_resource = """
provider "null" {}

resource "null_resource" "this" {}
"""

test_output = """
output "{random}" {{
    value = "{random}"
}}
"""

class TestSucceededRollbackProvider(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/global': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'approve'
                },
                'new_resources': ['null_resource.this'],
                'pr_files_content': [test_null_resource],
                'new_providers': ['hashicorp/null']
            }
        }
    }

class TestRejectedRollbackProvider(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/global': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'reject'
                },
                'new_resources': ['null_resource.this'],
                'pr_files_content': [test_null_resource],
                'new_providers': ['hashicorp/null']
            }
        }
    }    

class TestRevertNewProviderPRWithoutRollback(test_integration.Integration):
    case = {
        'head_ref': 'rollback',
        'revert_ref': TestRejectedRollbackProvider.case['head_ref'],
        'expect_failed_trigger_sf': True,
        'executions': {}
    }