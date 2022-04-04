from tests.integration import test_integration
import uuid
from tests.integration.helpers import dummy_tf_output, dummy_tf_provider_resource

class TestRejectRollbackProvider(test_integration.Integration):
    case = {
        'head_ref': f'feature-{uuid.uuid4()}',
        'executions': {
            'directory_dependency/dev-account/us-west-2/env-one/bar': {
                'actions': {
                    'deploy': 'approve',
                    'rollback_providers': 'reject'
                },
                'pr_files_content': [dummy_tf_provider_resource()],
                'expect_failed_rollback_providers_cw_trigger_sf': True
            },
            'directory_dependency/dev-account/us-west-2/env-one/foo': {
                'actions': {
                    'deploy': 'reject'
                },
                'pr_files_content': [dummy_tf_output()]
            }
        }
    }