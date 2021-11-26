import pytest
import os
import logging
from buildspecs.trigger_sf import TriggerSF
from psycopg2.sql import SQL
from helpers.utils import TestSetup
import uuid
import json

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="function", autouse=True)
def codebuild_env():
    os.environ['CODEBUILD_INITIATOR'] = 'rule/test'
    os.environ['EVENTBRIDGE_FINISHED_RULE'] = 'rule/test'
    os.environ['BASE_REF'] = 'master'

@pytest.fixture(scope="function", autouse=True)
def ts(conn, repo_url, function_repo_dir):
    return TestSetup(conn, repo_url, function_repo_dir, os.environ['GITHUB_TOKEN'])

@pytest.fixture()
def scenario_1(ts, test_id):
    '''
    CW Event: 
        status: success
        is_rollback: false
        is_base_rollback: false
        cfg_path: 1/2
    
    SF Execution:
        PR: Same as CW event
        commit: Same as CW event
        is_rollback: false
        is_base_rollback: false
        cfg_path: 2/2
    '''
    
    pr = ts.pr(base_ref=os.environ['BASE_REF'], head_ref=f'feature-{test_id}')

    pr.create_pr(status='running')

    pr.create_commit(
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
            },
            {
                'apply_changes': False,
                'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/bar',
                'create_provider_resource': False,
                'execution': {
                    'status': 'waiting',
                    'is_base_rollback': False,
                    'is_rollback': False,
                    'account_name': 'dev'
                }
            }
        ]
    )

    pr.insert_records()

    pr.collect_record_assertion('executions', {**json.loads(os.environ['EVENTBRIDGE_EVENT']), **{'status': 'success'}})
    pr.collect_record_assertion('commit_queue', {**pr.commit_records[0], **{'status': 'running'}})
    pr.collect_record_assertion('commit_queue', {**pr.pr_record, **{'status': 'running'}})

    return ts

@pytest.fixture
def run(scenario):
    log.debug(f"Scenario: {scenario}")
    TriggerSF().run()
    pass

@pytest.mark.parametrize("scenario", [
    ("scenario_1")
])
@pytest.mark.usefixtures("run")
def test_record_exists(cur, conn, scenario, request):
    scenario = request.getfixturevalue(scenario)

    log.info("Running record assertions:")
    for assertion in scenario.assertions:
        log.debug(f'Query:\n{assertion.as_string(conn)}')
        cur.execute(assertion)
