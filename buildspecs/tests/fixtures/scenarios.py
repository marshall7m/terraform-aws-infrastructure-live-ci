import pytest
import logging
import os
import psycopg2
import json
from helpers.utils import TestSetup

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope='function', autouse=True)
def account_dim(conn):
    return TestSetup.create_records(conn, 'account_dim', [
        {
            'account_name': 'dev',
            'account_path': 'directory_dependency/dev-account',
            'account_deps': [],
            'min_approval_count': 1,
            'min_rejection_count': 1,
            'voters': ['test-voter-1']
        }
    ])

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

    with TestSetup(psycopg2.connect(), repo_url, function_repo_dir, os.environ['GITHUB_TOKEN']) as ts:
        pr = ts.pr(base_ref=os.environ['BASE_REF'], head_ref=f'feature-{test_id}')

        pr.create_pr(status='running')

        pr.create_commit(
            status='running',
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
        cw_event = json.loads(os.environ['EVENTBRIDGE_EVENT'])
        pr.collect_record_assertion('executions', {**cw_event, **{'status': 'success'}}, [cw_event])
        pr.collect_record_assertion('commit_queue', {**pr.commit_records[0], **{'status': 'running'}}, [pr.commit_records[0]])
        pr.collect_record_assertion('pr_queue', {**pr.pr_record, **{'status': 'running'}}, [{'pr_id': pr.pr_record['pr_id']}])
        
    return ts

@pytest.fixture()
def scenario_2(test_id, repo_url, function_repo_dir):
    '''
    CW Event: 
        status: success
        is_rollback: false
        is_base_rollback: false
        cfg_path: 1/1
    
    SF Execution:
        PR: Same as CW event
        commit: New commit
        is_rollback: false
        is_base_rollback: false
        cfg_path: 1/2
    '''
    log.debug('Running scenario')
    
    with TestSetup(psycopg2.connect(), repo_url, function_repo_dir, os.environ['GITHUB_TOKEN']) as ts:
        pr = ts.pr(base_ref=os.environ['BASE_REF'], head_ref=f'feature-{test_id}')

        pr.create_pr(status='running')

        pr.create_commit(
            status='running',
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
                }
            ]
        )

        next_commit_path = 'directory_dependency/dev-account/us-west-2/env-one/bar'
        pr.create_commit(
            status='waiting',
            modify_items=[
                {
                    'apply_changes': False,
                    'cfg_path': next_commit_path,
                    'create_provider_resource': False,
                }
            ]
        )

        pr.insert_records()

        cw_event = json.loads(os.environ['EVENTBRIDGE_EVENT'])
        pr.collect_record_assertion('pr_queue', {**pr.pr_record, **{'status': 'running'}}, [pr.pr_record])

        pr.collect_record_assertion('commit_queue', {**pr.commit_records[0], **{'status': 'success'}}, [pr.commit_records[0]])
        pr.collect_record_assertion('executions', {**{'execution_id': cw_event['execution_id']}, **{'status': 'success'}}, [{'status': 'success'}])

        pr.collect_record_assertion('commit_queue', {**pr.commit_records[1], **{'status': 'running'}}, [pr.commit_records[1], {'status': 'running'}])
        pr.collect_record_assertion('executions', {'status': 'running', 'cfg_path': next_commit_path}, [{'commit_id': pr.commit_records[1]['commit_id']}, {'status': 'running'}])
        
    return ts

@pytest.fixture()
def scenario_3(test_id, repo_url, function_repo_dir):
    '''
    CW Event: 
        status: failed
        is_rollback: false
        is_base_rollback: false
        cfg_path: 1/1
    
    SF Execution:
        PR: Same as CW event
        commit: Same as CW event
        is_rollback: true
        is_base_rollback: true
        cfg_path: 1/1
    '''
    log.debug('Running scenario')
    
    with TestSetup(psycopg2.connect(), repo_url, function_repo_dir, os.environ['GITHUB_TOKEN']) as ts:
        pr = ts.pr(base_ref=os.environ['BASE_REF'], head_ref=f'feature-{test_id}')

        pr.create_pr(status='running')
        cw_cfg_path = 'directory_dependency/dev-account/us-west-2/env-one/doo'
        pr.create_commit(
            status='running',
            modify_items=[
                {
                    'apply_changes': True,
                    'cfg_path': cw_cfg_path,
                    'create_provider_resource': False,
                    'execution': {
                        'is_base_rollback': False,
                        'is_rollback': False,
                        'account_name': 'dev',
                        'cw_event_finished_status': 'failed'
                    }
                }
            ]
        )

        pr.create_commit(
            status='waiting',
            modify_items=[
                {
                    'apply_changes': False,
                    'cfg_path': 'directory_dependency/dev-account/us-west-2/env-one/bar',
                    'create_provider_resource': False,
                }
            ]
        )

        pr.insert_records()

        cw_event = json.loads(os.environ['EVENTBRIDGE_EVENT'])
        pr.collect_record_assertion('executions', {**cw_event, **{'status': 'failed'}}, [cw_event])
        
        pr.collect_record_assertion('commit_queue', {**pr.commit_records[0], **{'status': 'failed'}}, [pr.commit_records[0]])
        pr.collect_record_assertion('commit_queue', {**pr.commit_records[0], **{'status': 'running', 'is_rollback': True}}, [pr.commit_records[0]])
        pr.collect_record_assertion('commit_queue', {**pr.commit_records[1], **{'status': 'waiting'}}, [pr.commit_records[1]])

        pr.collect_record_assertion('executions', {
            'status': 'running',
            'cfg_path': cw_cfg_path,
            'commit_id': pr.get_base_commit_id(),
            'is_rollback': True,
            'is_base_rollback': True
        }, [pr.cw_execution])

        pr.collect_record_assertion('pr_queue', {**pr.pr_record, **{'status': 'running'}}, [pr.pr_record])
        
    return ts