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

def pytest_generate_tests(metafunc):
    if 'modify_items' in metafunc.fixturenames:
        metafunc.parametrize('modify_items', metafunc.cls.scenario['modify_items'], indirect=True)
    if 'target_execution' in metafunc.fixturenames:
        metafunc.parametrize('target_execution', list(range(0, len(metafunc.cls.scenario['executions']) + len(metafunc.cls.scenario['rollback_executions']))), indirect=True)
    if 'scenario' in metafunc.fixturenames:
        metafunc.parametrize('scenario', [metafunc.cls.scenario], scope='class')

    if metafunc.config.getoption('skip_init'):
        metafunc.parametrize('mut', [True], scope='class', indirect=True)
    if metafunc.config.getoption('skip_apply'):
        metafunc.parametrize('mut_output', [True], scope='class', indirect=True)

class TestScenarioOne(test_integration.TestIntegration):
    scenario = {
        'modify_items': [
            {
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                'content': test_null_resource
            }
        ],
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'action': 'approve'
            }
        }
    }

class TestScenarioTwo(test_integration.TestIntegration):
    scenario = {
        'modify_items': [
            {
                'cfg_path': 'directory_dependency/dev-account/global',
                'content': test_null_resource
            }
        ],
        'executions': {
            'directory_dependency/dev-account/global': {
                'action': 'approve'
            },
            'directory_dependency/dev-account/us-west-2/env-one/baz': {
                'action': 'approve'
            },
            'directory_dependency/dev-account/us-west-2/env-one/bar': {
                'action': 'reject'
            },
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'action': 'approve'
            },
            'directory_dependency/dev-account/us-west-2/env-one/foo': {
                'action': 'approve'
            }
        },
        'rollback_executions': {
            'directory_dependency/dev-account/global': {
                'action': 'approve',
                'new_resources': []
            }
        }
    }