from tests.integration import test_integration
import pytest

test_null_resource = """
provider "null" {}

resource "null_resource" "this" {}
"""

test_output = """
output "{random}" {{
    value = "{random}"
}}
"""

# class TestScenarioOne(test_integration.TestIntegration):
#     scenario = {
#         'modify_items': [
#             {
#                 'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
#                 'content': test_null_resource
#             }
#         ],
#         'executions': {
#             'directory_dependency/dev-account/us-west-2/env-one/doo': {
#                 'action': 'approve'
#             }
#         }
#     }

class TestScenarioTwo(test_integration.TestIntegration):
    scenario = {
        'directory_dependency/dev-account/global': {
            'actions': {
                'deploy': 'approve',
                'rollback_providers': 'approve',
                'rollback_base': 'approve'
            },
            'new_resources': [],
            'new_file_content': test_null_resource,
            'new_providers': ['hashicorp/null']
        },
        'directory_dependency/dev-account/us-west-2/env-one/baz': {
            'actions': {
                'deploy': 'approve',
                'rollback_base': 'approve'
            }
        },
        'directory_dependency/dev-account/us-west-2/env-one/bar': {
            'actions': {
                'deploy': 'reject',
                'rollback_base': 'approve'
            }
        },
        'directory_dependency/dev-account/us-west-2/env-one/doo': {
            'actions': {
                'deploy': 'approve',
                'rollback_base': 'approve'
            }
        },
        'directory_dependency/dev-account/us-west-2/env-one/foo': {
            'actions': {
                'deploy': 'approve',
                'rollback_base': 'approve'
            }
        }
    }