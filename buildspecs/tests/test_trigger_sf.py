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


def test_(test_id, conn, repo_url, function_repo_dir):
    ts = TestPRSetup(conn, repo_url, function_repo_dir, os.environ['GITHUB_TOKEN'], base_ref=os.environ['BASE_REF'], head_ref=f'feature-{test_id}')

    ts.create_commit(
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
    ts.create_pr(status='waiting')

    ts.insert_records()

    # TriggerSF()

    # ts.assert_record_count()
    