import pytest
import os
import logging
from buildspecs.trigger_sf import TriggerSF
from psycopg2.sql import SQL
from helpers.utils import TestSetup
import uuid

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope="function", autouse=True)
def codebuild_env():
    os.environ['CODEBUILD_INITIATOR'] = 'rule/test'
    os.environ['EVENTBRIDGE_FINISHED_RULE'] = 'rule/test'
    os.environ['BASE_REF'] = 'master'

@pytest.fixture()
def scenario_1(conn, repo_url, function_repo_dir, test_id):

    """Successful CW event -- dequeue next commit -- start SF execution with 1/1 cfg path"""
    ts = TestSetup(conn, repo_url, function_repo_dir, os.environ['GITHUB_TOKEN'])
    
    pr = ts.pr(base_ref=os.environ['BASE_REF'], head_ref=f'feature-{test_id}')
    pr.create_commit(
        status='waiting',
        modify_items=[
            {
                'assert_conditions': {
                    'status': 'success',
                },
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
    pr.create_pr(status='waiting')

    pr.collect_record_assertion('executions', os.environ['EVENTBRIDGE_EVENT'], {'status': 'success'})
    pr.collect_record_assertion('commit_queue', pr.commit_records[0], {'status': 'success'})

    return ts


# @pytest.fixture
# def run(scenario):
#     # TriggerSF().run()
#     pass

@pytest.mark.parametrize("scenario", [
    ("scenario_1")
])
# @pytest.mark.usefixtures("run")
def test_record_exists(cur, scenario, request):
    scenario = request.getfixturevalue(scenario)
    for assertion in scenario.assertions:
        log.debug(f'Query:\n{assertion}')
        cur.execute(assertion)
