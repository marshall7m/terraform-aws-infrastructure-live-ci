from tests.integration import test_integration
from tests.integration.helpers import dummy_tf_output
import uuid

class TestSucceededDeployment(test_integration.Integration):
    '''
    Case covers a simple 2 node deployment with one node having an account-level dependency on the other.
    See the account_dim table to see the account dependency testing layout.
    '''
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
    '''
    Case covers a simple 2 node deployment with one node having an account-level dependency on the other.
    See the account_dim table to see the account dependency testing layout.
    The rejection of the first deployment's approval should cause the second planned deployment to be aborted
    and not have an associated Step Function execution created.
    '''
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