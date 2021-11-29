import psycopg2
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
    os.environ['AWS_DEFAULT_REGION'] = 'us-west-2'

    os.environ['DRY_RUN'] = 'true'
    os.environ['PGOPTIONS'] = '-c statement_timeout=100000'

@pytest.fixture()
def scenario_1(test_id, repo_url, function_repo_dir):
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
    log.debug('Running scenario')
    conn = psycopg2.connect()
    with TestSetup(conn, repo_url, function_repo_dir, os.environ['GITHUB_TOKEN']) as ts:
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
                        'is_base_rollback': False,
                        'is_rollback': False,
                        'account_name': 'dev',
                        'cw_event_finished_status': 'success'
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
        pr.collect_record_assertion('pr_queue', {**pr.pr_record, **{'status': 'running'}})
        
    return ts

@pytest.mark.parametrize("scenario", [
    ("scenario_1")
])
def test_record_exists(scenario, request):
    log.debug(f"Scenario: {scenario}")
    scenario = request.getfixturevalue(scenario)


    #TODO: Figure out how to put trigger.main() within fixture thats dependent on scenario and calls .cleanup() yielding .main()
    trigger = TriggerSF()
    try:
        trigger.main()
    except Exception as e:
        log.error(e)
        raise
    finally:
        trigger.cleanup()

    log.info("Running record assertions:")
    with psycopg2.connect() as conn:
        scenario.run_collected_assertions(conn)
