import psycopg2
import pytest
import mock
import os
import logging
import sys
from buildspecs.trigger_sf import TriggerSF
from psycopg2.sql import SQL
import pandas.io.sql as psql
from helpers.utils import TestSetup

import uuid
import json

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope='class')
def account_dim(ts, conn):
    yield ts.create_records(conn, 'account_dim', [
        {
            'account_name': 'dev',
            'account_path': 'directory_dependency/dev-account',
            'account_deps': [],
            'min_approval_count': 1,
            'min_rejection_count': 1,
            'voters': ['test-voter-1']
        }
    ])

    ts.truncate_if_exists(conn, 'public', conn.info.dbname, 'account_dim')

# mock step function boto3 client
@pytest.fixture(scope='class')
@mock.patch('buildspecs.trigger_sf.sf')
def run(mock_aws, class_repo_dir, account_dim, scenario, request):
    os.chdir(class_repo_dir)
    log.debug(f'CWD: {os.getcwd()}')

    trigger = TriggerSF()
    return trigger.main()

    trigger.cleanup()

@pytest.fixture(scope='class')
def ts(repo_url, class_repo_dir):
    return TestSetup(psycopg2.connect(), repo_url, class_repo_dir, os.environ['GITHUB_TOKEN'])
    

# @pytest.mark.skip(reason="Marked on a class, the entire class and the methods in the class will not be executed!")
@pytest.mark.parametrize("scenario", [
    ("scenario_1"),
    ("scenario_2"),
    ("scenario_3")
], scope='class')

@pytest.mark.usefixtures("account_dim", "run")
class TestMergeTrigger:
        
    @pytest.fixture(scope="class", autouse=True)
    def codebuild_env(self, scenario, request):
        scenario = request.getfixturevalue(scenario)
        
        os.environ['CODEBUILD_WEBHOOK_TRIGGER'] = 'pr/1'
        os.environ['CODEBUILD_WEBHOOK_BASE_REF'] = scenario.base_ref
        os.environ['CODEBUILD_WEBHOOK_HEAD_REF'] = scenario.head_ref
        os.environ['CODEBUILD_INITIATOR'] = 'GitHub-Hookshot/0000001'
        os.environ['CODEBUILD_SOURCE_VERSION'] = scenario.commit_ids[0]
        os.environ['STATE_MACHINE_ARN'] = 'mock-sf-arn'
        
        os.environ['AWS_DEFAULT_REGION'] = 'us-west-2'
        os.environ['PGOPTIONS'] = '-c statement_timeout=100000'
    
    @pytest.fixture(scope="class")
    def scenario_1(self, scenario_id, ts):
        'Leaf execution is running with no new provider resources'

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        commit = pr.create_commit(
            modify_items=[
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                    'create_provider_resource': False,
                    'record_assertion': {'status': 'running'}
                }
            ]
        )

        pr.merge()

        return pr

    @pytest.fixture(scope="class")
    def scenario_2(self, scenario_id, ts):
        'Leaf execution is running with new provider resource'

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
            modify_items=[
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                    'create_provider_resource': True,
                    'record_assertion': {'status': 'running', 'new_provider_resources': True}
                }
            ]
        )

        pr.merge()
        
        return pr
    
    @pytest.fixture(scope="class")
    def scenario_3(self, scenario_id, ts):
        'Root dependency execution is running and leaf execution is waiting'

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
            modify_items=[
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/global',
                    'create_provider_resource': False,
                    'record_assertion': {'status': 'running'}
                },
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                    'create_provider_resource': True,
                    'record_assertion': {'status': 'waiting', 'new_provider_resources': True}
                }
            ]
        )

        pr.merge()
        
        return pr

    def test_execution_record_exists(self, scenario, conn, request):
        log.debug(f"Scenario: {scenario}")
        scenario = request.getfixturevalue(scenario)
        
        scenario.run_collected_assertions()



@pytest.mark.skip(reason="Not implemented")
@pytest.mark.parametrize("scenario", [
    ("scenario_1")
    # ("scenario_2"),
    # ("scenario_3")
])
class TestCloudWatchEvent(object):
    @pytest.fixture(scope="function", autouse=True)
    def codebuild_env(self):
        os.environ['CODEBUILD_INITIATOR'] = 'rule/test'
        os.environ['EVENTBRIDGE_FINISHED_RULE'] = 'rule/test'

        os.environ['AWS_DEFAULT_REGION'] = 'us-west-2'
        os.environ['STATE_MACHINE_ARN'] = 'mock-sf-arn'

        os.environ['PGOPTIONS'] = '-c statement_timeout=100000'

    @pytest.fixture(scope="class")
    def scenario_1(self, scenario_id, ts):
        'CW root dependency execution was successful, branch execution is running, and leaf execution is waiting'

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
            modify_items=[
                {
                    'apply_changes': True,
                    'cfg_path': 'directory_dependency/dev-account/global',
                    'create_provider_resource': False,
                    'record': {
                        'is_rollback': False,
                        'account_name': 'dev',
                        'cw_event_finished_status': 'success'
                    },
                    'record_assertion': {'status': 'success'}
                },
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/baz',
                    'create_provider_resource': False,
                    'record': {
                        'is_rollback': False,
                        'account_name': 'dev'
                    },
                    'record_assertion': {'status': 'running'}
                },
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/bar',
                    'create_provider_resource': False,
                    'record': {
                        'is_rollback': False,
                        'account_name': 'dev'
                    },
                    'record_assertion': {'status': 'waiting'}
                }
            ]
        )

        pr.merge()
        
        return pr
    
    @pytest.fixture(scope="class")
    def scenario_2(self, scenario_id, ts):
        'CW root dependency execution with new provider resource was successful and no target executions are waiting'

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
            modify_items=[
                {
                    'apply_changes': True,
                    'cfg_path': 'directory_dependency/dev-account/global',
                    'create_provider_resource': True,
                    'record': {
                        'is_rollback': False,
                        'account_name': 'dev',
                        'cw_event_finished_status': 'success'
                    },
                    'record_assertion': {'status': 'success', 'new_provider_resources': True}
                }
            ]
        )

        pr.merge()
        
        return pr
    
    @pytest.fixture(scope="class")
    def scenario_3(self, scenario_id, ts):
        'CW root dependency execution with new provider resource was failed and no target executions are waiting'

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
            modify_items=[
                {
                    'apply_changes': True,
                    'cfg_path': 'directory_dependency/dev-account/global',
                    'create_provider_resource': True,
                    'record': {
                        'is_rollback': False,
                        'account_name': 'dev',
                        'cw_event_finished_status': 'failed'
                    },
                    'record_assertion': {'status': 'failed', 'new_provider_resources': True}
                }
            ]
        )

        pr.merge()
        
        return pr
    
    def test_execution_record_exists(self, scenario, conn, request):
        log.debug(f"Scenario: {scenario}")
        scenario = request.getfixturevalue(scenario)
        
        scenario.run_collected_assertions()