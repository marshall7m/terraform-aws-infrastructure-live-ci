from tests.integration import test_integration
from tests.integration.helpers import dummy_tf_output
import uuid

class TestSucceededDeployment(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/shared-services-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve'
                },
                'pr_files_content': [dummy_tf_output()]
            },
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'approve'
                },
                'pr_files_content': [dummy_tf_output()]
            }
        }
    }

class TestRejectedDeployment(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/shared-services-account/us-west-2/env-one/doo': {
                'actions': {
                    'deploy': 'reject'
                },
                'pr_files_content': [dummy_tf_output()]
            },
            'directory_dependency/dev-account/us-west-2/env-one/doo': {
                'sf_execution_exists': False,
                'pr_files_content': [dummy_tf_output()]
            }
        }
    }