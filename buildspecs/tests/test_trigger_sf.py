import psycopg2
from psycopg2 import sql
import pytest
import mock
import os
import logging
import sys
from buildspecs.trigger_sf import TriggerSF
from psycopg2.sql import SQL
import pandas.io.sql as psql
from helpers.utils import TestSetup
import shutil
import uuid
import json
import git

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

def pytest_generate_tests(metafunc):
    scenarios = []
    for attr in metafunc.cls.__dict__.keys():
        parse_attr = attr.split('_')
        id = parse_attr[1] if parse_attr[1:] else ''
        if parse_attr[0] == 'scenario' and id.isdigit():
            scenarios.append(attr)
    
    scenario_fixt = "scenario,class_repo_dir,class_tf_state_dir,create_metadb_tables"
    scenario_params = [pytest.param(*[scenario] * len(scenario_fixt.split(',')), id=scenario) for scenario in scenarios]
    metafunc.parametrize(scenario_fixt, scenario_params, indirect=True)

@pytest.fixture(scope='class')
def account_dim(conn):
    TestSetup.create_records(conn, 'account_dim', [
        {
            'account_name': 'dev',
            'account_path': 'directory_dependency/dev-account',
            'account_deps': [],
            'min_approval_count': 1,
            'min_rejection_count': 1,
            'voters': ['test-voter-1']
        }
    ])

    yield

    TestSetup.truncate_if_exists(conn, 'public', conn.info.dbname, 'account_dim')

# mock step function boto3 client
@pytest.fixture(scope='class')
@mock.patch('buildspecs.trigger_sf.sf')
def run(mock_aws, scenario):
    os.chdir(scenario.git_dir)
    log.debug(f'CWD: {os.getcwd()}')

    trigger = TriggerSF()

    return trigger.main()

@pytest.fixture(scope='class')
def ts(repo_url, class_repo_dir):
    return TestSetup(psycopg2.connect(), repo_url, class_repo_dir, os.environ['GITHUB_TOKEN'])

@pytest.fixture(scope="class")
def scenario(request, account_dim, class_repo_dir, class_tf_state_dir, create_metadb_tables, ts):
    return request.getfixturevalue(request.param)

# @pytest.mark.skip(reason="Not implemented")
@pytest.mark.usefixtures("account_dim", "scenario", "class_repo_dir", "class_tf_state_dir", "create_metadb_tables", "ts", "run")
class TestMergeTrigger:
    @pytest.fixture(scope="class", autouse=True)
    def codebuild_env(self, scenario):
        os.environ['CODEBUILD_WEBHOOK_TRIGGER'] = 'pr/1'
        os.environ['CODEBUILD_WEBHOOK_BASE_REF'] = scenario.base_ref
        os.environ['CODEBUILD_WEBHOOK_HEAD_REF'] = scenario.head_ref
        os.environ['CODEBUILD_INITIATOR'] = 'GitHub-Hookshot/0000001'
        os.environ['CODEBUILD_SOURCE_VERSION'] = scenario.commit_ids[0]
        os.environ['STATE_MACHINE_ARN'] = 'mock-sf-arn'
        
        os.environ['AWS_DEFAULT_REGION'] = 'us-west-2'
        os.environ['PGOPTIONS'] = '-c statement_timeout=100000'
    
    @pytest.fixture(scope="class")
    def scenario_1(self, scenario_id, session_repo_dir, repo_url, tmp_path_factory):
        'Leaf execution is running with no new provider resources'

        dir = str(tmp_path_factory.mktemp('class-repo'))
        log.debug(f'Class repo dir: {dir}')
        git.Repo.clone_from(session_repo_dir, dir)
        ts = TestSetup(psycopg2.connect(), repo_url, dir, os.environ['GITHUB_TOKEN'])

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
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

        yield pr

    @pytest.fixture(scope="class")
    def scenario_2(self, scenario_id, session_repo_dir, repo_url, tmp_path_factory):
        'Leaf execution is running with new provider resource'

        dir = str(tmp_path_factory.mktemp('class-repo'))
        log.debug(f'Class repo dir: {dir}')

        git.Repo.clone_from(session_repo_dir, dir)
        
        ts = TestSetup(psycopg2.connect(), repo_url, dir, os.environ['GITHUB_TOKEN'])

        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
            modify_items=[
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/doo',
                    'create_provider_resource': True,
                    'record_assertion': {'status': 'running', 'assert_new_provider': True}
                }
            ]
        )

        pr.merge()
        
        yield pr
    
    @pytest.fixture(scope="class")
    def scenario_3(self, scenario_id, session_repo_dir, repo_url, tmp_path_factory):
        'Root dependency execution is running and leaf execution is waiting'

        dir = str(tmp_path_factory.mktemp('class-repo'))
        log.debug(f'Class repo dir: {dir}')
        
        git.Repo.clone_from(session_repo_dir, dir)

        ts = TestSetup(psycopg2.connect(), repo_url, dir, os.environ['GITHUB_TOKEN'])

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
                    'record_assertion': {'status': 'waiting', 'assert_new_provider': True},
                    'debug_conditions': [{'status': 'waiting'}]
                }
            ]
        )

        pr.merge()

        yield pr

    def test_execution_record_exists(self, scenario):
        log.debug(f"Scenario: {scenario}")        
        scenario.run_collected_assertions()

@pytest.mark.usefixtures("account_dim", "scenario", "class_repo_dir", "class_tf_state_dir", "create_metadb_tables", "ts", "run")
class TestCloudWatchEvent:
    @pytest.fixture(scope="class", autouse=True)
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
                        'status': 'running',
                        'is_rollback': False,
                        'account_name': 'dev',
                    },
                    'cw_event_finished_status': 'success',
                    'record_assertion': {'status': 'success'},
                    'debug_conditions': [{'cfg_path': 'directory_dependency/dev-account/global'}]
                },
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/baz',
                    'create_provider_resource': False,
                    'record': {
                        'status': 'waiting',
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
                        'status': 'waiting',
                        'cfg_deps': ['directory_dependency/dev-account/us-west-2/env-one/baz'],
                        'is_rollback': False,
                        'account_name': 'dev'
                    },
                    'record_assertion': {'status': 'waiting'}
                }
            ]
        )

        pr.merge()
        
        yield pr
    
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
                        'status': 'running',
                        'is_rollback': False,
                        'account_name': 'dev'
                    },
                    'cw_event_finished_status': 'success',
                    'record_assertion': {'status': 'success', 'assert_new_provider': True, 'assert_new_resource': True},
                    'debug_conditions': [{'cfg_path': 'directory_dependency/dev-account/global'}]
                }
            ]
        )

        pr.merge()
        
        yield pr

    @pytest.fixture(scope="class")
    def scenario_3(self, scenario_id, ts):
        'CW root dependency execution with new provider resource failed and associated rollback execution is running'
        
        pr = ts.pr(base_ref='master', head_ref=f'feature-{scenario_id}')

        pr.create_commit(
            modify_items=[
                {
                    'apply_changes': True,
                    'cfg_path': 'directory_dependency/dev-account/global',
                    'create_provider_resource': True,
                    'record': {
                        'status': 'running',
                        'is_rollback': False,
                        'account_name': 'dev'
                    },
                    'cw_event_finished_status': 'failed',
                    'record_assertion': {'status': 'failed', 'assert_new_provider': True, 'assert_new_resource': True},
                    'debug_conditions': [{'cfg_path': 'directory_dependency/dev-account/global'}]
                }
            ]
        )

        #TODO: assert rollback execution is running

        pr.merge()
        
        yield pr
    def test_execution_record_exists(self, scenario):
        log.debug(f"Scenario: {scenario}")
        scenario.run_collected_assertions()
