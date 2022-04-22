from tests.integration import test_integration
import uuid
from tests.helpers.utils import dummy_tf_provider_resource

class TestBasePR(test_integration.Integration):
    '''TODO'''
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/baz': {
                'actions': {
                    'deploy': 'approve'
                },
                'pr_files_content': [dummy_tf_provider_resource()]
            },
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

class TestDeployPR(test_integration.Integration):
    '''TODO'''
    # depends_on = {
    #     'class': ['TestBasePR'],
    #     'tests': []
    # }
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/global': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'approve'
                },
                'pr_files_content': [dummy_tf_provider_resource()]
            },
            'directory_dependency/dev-account/us-west-2/env-one/baz': {
                'actions': {
                    'deploy': 'approve'
                },
                'pr_files_content': ['resource "null_resource" "baz" {}']
            },
            'directory_dependency/dev-account/us-west-2/env-one/bar': {
                'actions': {
                    'deploy': 'reject'
                }
            },
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve'
                }
            },
            'directory_dependency/dev-account/us-west-2/env-one/foo': {
                'sf_execution_exists': False
            }
        }
    }

class TestRevertPR(test_integration.Integration):
    '''TODO'''
    case = {
        'head_ref': f'revert-{TestDeployPR.case["head_ref"]}',
        'revert_ref': TestDeployPR.case['head_ref'],
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/baz': {
                'actions': {
                    'deploy': 'approve'
                }
            },
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