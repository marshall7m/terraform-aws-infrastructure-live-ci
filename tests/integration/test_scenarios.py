from tests.integration import test_integration

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
    if 'execution_record' in metafunc.fixturenames:
        metafunc.parametrize('execution_record', list(range(0, len(metafunc.cls.scenario['executions']))), indirect=True)
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
                'approve_all': True
            }
        }
    }

    # def test_null_resource(self):
    #     pass