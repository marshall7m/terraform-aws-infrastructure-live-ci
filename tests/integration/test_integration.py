import subprocess
import pytest
from unittest.mock import patch
import os
import logging
import sys
from psycopg2.sql import SQL
import shutil
import uuid
import json
import time
import github
import timeout_decorator
import random
import string
from pytest_dependency import depends
import boto3

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TestIntegration:

    @pytest.fixture(scope='class', autouse=True)
    def truncate_executions(self, conn):
        #table setup is within tf module
        #yielding none to define truncation as pytest teardown logic
        yield None
        log.info('Truncating executions table')
        with conn.cursor() as cur:
            cur.execute("TRUNCATE executions")

    # list of PRs with directory to create test files within
    # explicitly defining execution testing order until fixture list return values can be used to parametrize fixtures/tests
    # at the execution phase of pytest
    # see: https://stackoverflow.com/questions/50231627/python-pytest-unpack-fixture/56865893#56865893
    @pytest.fixture(scope='class')
    def pr(self, repo, scenario):
        os.environ['BASE_REF'] = 'master'
        os.environ['HEAD_REF'] = f'feature-{uuid.uuid4()}'

        base_commit = repo.get_branch(os.environ['BASE_REF'])
        head_ref = repo.create_git_ref(ref='refs/heads/' + os.environ['HEAD_REF'], sha=base_commit.commit.sha)
        elements = []
        for item in scenario['modify_items']:
            filepath = item['cfg_path'] + '/' + ''.join(random.choice(string.ascii_lowercase) for _ in range(8)) + '.tf'
            log.debug(f'Creating file: {filepath}')
            blob = repo.create_git_blob(item['content'], "utf-8")
            elements.append(github.InputGitTreeElement(path=filepath, mode='100644', type='blob', sha=blob.sha))

        head_sha = repo.get_branch(os.environ['HEAD_REF']).commit.sha
        base_tree = repo.get_git_tree(sha=head_sha)
        tree = repo.create_git_tree(elements, base_tree)
        parent = repo.get_git_commit(sha=head_sha)
        commit_id = repo.create_git_commit("commit_message", tree, [parent]).sha
        head_ref.edit(sha=commit_id)

        
        log.info('Creating PR')
        pr = repo.create_pull(title=f"test-{os.environ['HEAD_REF']}", body='test', base=os.environ['BASE_REF'], head=os.environ['HEAD_REF'])
        
        log.debug(f'head ref commit: {commit_id}')
        log.debug(f'pr commits: {pr.commits}')

        yield {
            'number': pr.number,
            'head_commit_id': commit_id
        }

        try:
            log.info('Closing PR')
            pr.edit(state='closed')
        except Exception:
            pass
    

    @pytest.fixture(scope="class")
    def scenario(self, request):
        return request.param

    @pytest.fixture(scope="class")
    def execution(self, request):
        return request.param
    
    @pytest.fixture(scope='class')
    @timeout_decorator.timeout(300)
    def merge_lock_status(self, cb, mut_output, pr):
        log.info('Waiting on merge lock Codebuild executions to finish')
        return self.get_build_status(cb, mut_output["codebuild_merge_lock_name"], pr["number"])

    @pytest.mark.dependency()
    def test_merge_lock_codebuild(self, request, merge_lock_status):
        """Assert scenario's associated merge_lock codebuild was successful"""
        log.info('Assert build succeeded')
        assert all(status == 'SUCCEEDED' for status in merge_lock_status)

    @pytest.mark.dependency()
    def test_merge_lock_pr_status(self, request, repo, pr):
        """Assert PR's head commit ID has a successful merge lock status"""
        log.debug(f'Test Class: {request.cls.__name__}')
        depends(request, [f'{request.cls.__name__}::test_merge_lock_codebuild[{request.node.callspec.id}]'])

        log.info('Assert PR head commit status is successful')
        log.debug(f'PR head commit: {pr["head_commit_id"]}')
        
        assert repo.get_commit(pr["head_commit_id"]).get_statuses()[0].state == 'success'

    def get_build_status(self, client, name, pr_num):

        statuses = ['IN_PROGRESS']
        wait = 60

        while 'IN_PROGRESS' in statuses:
            time.sleep(wait)
            ids = client.list_builds_for_project(
                projectName=name,
                sortOrder='DESCENDING'
            )['ids']

            if len(ids) == 0:
                log.error(f'No builds have runned for project: {name}')
                sys.exit(1)
            statuses = [build['buildStatus'] for build in client.batch_get_builds(ids=ids)['builds'] if build.get('sourceVersion', None) == f'pr/{pr_num}']
            
            log.debug(f'Statuses: {statuses}')
            if len(statuses) == 0:
                log.error(f'No build have been triggered for PR: {pr_num} within {wait} secs')
                sys.exit(1)
    
        return statuses

    @pytest.fixture(scope='class')
    @timeout_decorator.timeout(300)
    def trigger_sf_status(self, cb, mut_output, pr, merge_pr):
        log.info('Waiting on trigger sf Codebuild execution to finish')

        return self.get_build_status(cb, mut_output["codebuild_trigger_sf_name"], pr["number"])

    @pytest.mark.dependency()
    def test_trigger_sf_codebuild(self, request, trigger_sf_status):
        """Assert scenario's associated trigger_sf codebuild was successful"""
        depends(request, [f'{request.cls.__name__}::test_merge_lock_pr_status[{request.node.callspec.id}]'])

        log.info('Assert build succeeded')
        assert len(trigger_sf_status) == 1
        assert trigger_sf_status[0] == 'SUCCEEDED'
    
    @pytest.mark.dependency()
    def test_executions_exists(self, request, conn, scenario, pr):
        """Assert that all expected scenario directories are within executions table"""
        depends(request, [f'{request.cls.__name__}::test_trigger_sf_codebuild[{request.node.callspec.id}]'])

        with conn.cursor() as cur:
            cur.execute(f"""
            SELECT array_agg(execution_id::TEXT)
            FROM executions 
            WHERE commit_id = '{pr["head_commit_id"]}'
            """
            )
            ids = cur.fetchone()[0]
        if ids == None:
            target_execution_ids = []
        else:
            target_execution_ids = [id for id in ids]
        
        log.debug(f'Commit execution IDs:\n{target_execution_ids}')
        assert len(scenario['executions']) == len(target_execution_ids)

    @pytest.fixture(scope="class")
    def execution_record(self, conn, pr, trigger_sf_status):
        with conn.cursor() as cur:
            cur.execute(f"""
                SELECT 1 
                FROM executions 
                WHERE commit_id = '{pr["head_commit_id"]}'
                AND status = 'running'
            """)
            record = cur.fetchone()
            if record == None:
                log.error('No execution records have a status of running within commit')
                sys.exit(1)
            else:
                return record[0]
    
    @pytest.mark.dependency()
    def test_sf_execution_running(self, request, mut_output, sf, execution_record, scenario):
        """Assert running execution record has a running Step Function execution"""
        depends(request, [f'{request.cls.__name__}::test_executions_exists[{request.node.callspec.id}]'])

        executions = sf.list_executions(
            stateMachineArn=mut_output['state_machine_arn'],
            statusFilter='RUNNING'
        )['executions']
        running_ids = [execution['name'] for execution in executions]

        log.debug(f'Metadb execution record:\n{execution_record}')
        log.debug(f'Step Function running execution IDs:\n{running_ids}')

        assert execution_record['execution_id'] in running_ids

    # @timeout_decorator.timeout(300)
    # @pytest.mark.dependency()
    # def test_terr_run_plan_codebuild(self, request, sf, mut_output):
    #     """Assert scenario's associated trigger_sf codebuild was successful"""
    #     depends(request, [f'{request.cls.__name__}::test_sf_execution_running[{request.node.callspec.id}]'])

    #     log.info('Assert build succeeded')
    #     assert status == 'SUCCEEDED'

    # def test_approval_request(cfg, s3):
    #     #while running executions' approval response is not finished, check if s3 bucket received requests
    #     obj = s3.get_object(Bucket=os.environ['TESTING_BUCKET_NAME'], Key=os.environ['TESTING_EMAIL_S3_KEY'])
    #     action_url = json.loads(obj['Body'].read())[cfg['action']]
        
    #     out = subprocess.run(["ping", "-c", action_url], capture_output=True, check=True)
    
    # @timeout_decorator.timeout(300)
    # @pytest.mark.dependency()
    # def test_terr_run_apply_codebuild(self, request, cb, mut_output):
    #     """Assert scenario's associated trigger_sf codebuild was successful"""
    #     depends(request, [f'{request.cls.__name__}::test_sf_execution_running[{request.node.callspec.id}]'])

    #     status = self.get_build_status(cb, mut_output["codebuild_terra_run_name"], {<filter>})[0]

    #     log.info('Assert build succeeded')
    #     assert status == 'SUCCEEDED'

    # def test_applied_changes(self, execution):
    #     # run tg plan -detailed-exitcode and assert return code is == 0
    #     pass

    # def test_cw_event_sent(self):
    #     pass
