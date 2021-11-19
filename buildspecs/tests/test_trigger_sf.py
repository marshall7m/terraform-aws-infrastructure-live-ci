import pytest
import os
import logging
from buildspecs.trigger_sf import TriggerSF
from psycopg2.sql import SQL

from buildspecs.tests.fixtures import mock_tables

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
                            'executions': [
                                {
                                    'record_items': {
                                        'status': 'running',
                                        'is_base_rollback': False,
                                        'is_rollback': False,
                                        'account_name': 'dev'
                                    },
                                    'apply_changes': True,
                                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                                    'create_provider_resource': False,
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
                            'executions': [
                                {
                                    'record_items': {
                                        'status': 'waiting',
                                        'is_base_rollback': False,
                                        'is_rollback': False,
                                        'account_name': 'dev'
                                    },
                                    'apply_changes': True,
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

    @pytest.fixture(params=test_data, autouse=True)
    def mock_pr(self, cur, conn, request):
        results = []
        for pr in request.param['prs']:
            results.extend(mock_tables.mock_table(
                cur, 
                conn,
                'pr_queue', 
                pr['record_items'],
                enable_defaults=pr['enable_defaults'],
                update_parents=False
            ))
        
        yield results
    
    def test_record_item(self, mock_pr):
        assert mock_pr == {}
# def mock_commits(pr_data):
#     for commit in pr_data.commits:
#         results = mock_table(cur, 'commit_queue', commit.record_items, enable_defaults=commit.enable_defaults, update_parents=commit.update_parents)
#         pr_data.commit_queue = pr_data.commit_queue.append(results)

# def mock_executions(pr_data):
#     for commit in pr_data.commits:
#         for execution in commit.execution:
#             results = mock_table(cur, 'executions', execution.record_items, enable_defaults=execution.enable_defaults, update_parents=execution.update_parents)
#             pr_data.executions = pr_data.executions.append(results)

# @pytest.fixture(scope="function", autouse=True)
# def run():
#     trigger = TriggerSF()

# def record_exists_assertions(table, conditions, assertions):
#     sql = SQL("".format())
#     log.debug(f'Assertion: {sql}')
#     assertions.append(sql)