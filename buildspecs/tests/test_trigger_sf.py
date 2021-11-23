import pytest
import os
import logging
from buildspecs.trigger_sf import TriggerSF
from psycopg2.sql import SQL
from helpers.utils import TestPRSetup
import uuid

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="function", autouse=True)
def codebuild_env():
    os.environ['CODEBUILD_INITIATOR'] = 'rule/test'
    os.environ['EVENTBRIDGE_FINISHED_RULE'] = 'rule/test'
    os.environ['BASE_REF'] = 'master'

class TestTriggerSF:
    test_data = [
        {
            'prs': [
                {
                    'record_items': {
                        'status': 'running',
                    },
                    #TODO incorporate assert status fixture that collects all assertions for testing
                    'assert_status': 'success',
                    'enable_defaults': True,
                    'create_remote': False,
                    'commits': [
                        {
                            'record_items': {'status': 'running'},
                            'enable_defaults': True,
                            'apply_changes': True,
                            'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                            'create_provider_resource': False,
                            'executions': [
                                {
                                    'record_items': {
                                        'status': 'running',
                                        'is_base_rollback': False,
                                        'is_rollback': False,
                                        'account_name': 'dev'
                                    },
                                    'enable_defaults': True,
                                    'cw_finished_status': 'success'
                                }
                            ]
                        }
                    ]
                },
                {
                    'record_items': {
                        'status': 'running',
                        'head_ref': 'feature-2'
                    }, 
                    'enable_defaults': True,
                    'create_remote': False,
                    'commits': [
                        {
                            'record_items': {'status': 'waiting'},
                            'enable_defaults': True,
                            'executions': [
                                {
                                    'record_items': {
                                        'status': 'waiting',
                                        'is_base_rollback': False,
                                        'is_rollback': False,
                                        'account_name': 'dev'
                                    },
                                    'apply_changes': True,
                                    'enable_defaults': True,
                                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/foo',
                                    'create_provider_resource': False,
                                    'cw_finished_status': 'success'
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    ]

def test_record_item(test_id, conn, repo_url, function_repo_dir):
    ts = TestPRSetup(conn, repo_url, function_repo_dir, os.environ['GITHUB_TOKEN'], base_ref=os.environ['BASE_REF'], head_ref=f'feature-{test_id}')

    ts.create_commit(
        status='waiting',
        modify_items=[
            {
                'apply_changes': True,
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                'create_provider_resource': False,
                'execution': {
                    'status': 'running',
                    'is_base_rollback': False,
                    'is_rollback': False,
                    'account_name': 'dev',
                    'is_cw_event': True
                }
            }
        ]
    )
    ts.create_pr(status='waiting')

    ts.insert_records()

    cur = conn.cursor()
    cur.execute('SELECT * FROM commit_queue')

    cur.execute('SELECT * FROM executions')
    # trigger = TriggerSF()

    # for assertion in mock_setup.assertions:
    #     cur.execute(assertion)