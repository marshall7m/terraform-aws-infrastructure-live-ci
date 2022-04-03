from tests.integration import test_integration
import uuid

test_null_resource = """
provider "null" {}

resource "null_resource" "this" {}
"""

test_output = f"""
output "_{uuid.uuid4()}" {{
    value = "_{uuid.uuid4()}"
}}
"""

class TestRejectRollbackProvider(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/bar': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'reject'
                },
                'new_resources': ['null_resource.this'],
                'pr_files_content': [test_null_resource],
                'new_providers': ['hashicorp/null'],
                'expect_failed_rollback_providers_cw_trigger_sf': True
            },
            'directory_dependency/dev-account/us-west-2/env-one/foo': {
                'actions': {
                    'deploy': 'reject'
                },
                'pr_files_content': [test_output]
            }
        }
    }