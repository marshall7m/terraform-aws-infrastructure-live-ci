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

class TestSucceededDeployment(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve'
                },
                'pr_files_content': [test_output]
            },
            'directory_dependency/shared-services-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve'
                },
                'pr_files_content': [test_output]
            }
        }
    }

# class TestRejectedDeployment(test_integration.Integration):
#     case = {
#         'head_ref': f'feature-{uuid.uuid4()}',
#         'executions': {
#             'directory_dependency/dev-account/global': {
#                 'actions': {
#                     'deploy': 'reject'
#                 },
#                 'pr_files_content': [test_output]
#             }
#         }
#     }