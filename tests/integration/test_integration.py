import subprocess
import psycopg2
from psycopg2 import sql
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

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TestIntegration:

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
        ids = cb.list_builds_for_project(
            projectName=mut_output['codebuild_merge_lock_name'],
            sortOrder='DESCENDING'
        )['ids']
        
        
        log.info('Waiting on merge lock Codebuild executions to finish')
        log.debug(f'Codebuild IDs: {ids}')

        statuses = ['IN_PROGRESS']
        wait = 60
        while 'IN_PROGRESS' in statuses:
            time.sleep(wait)
            statuses = [build['buildStatus'] for build in cb.batch_get_builds(ids=ids)['builds'] if build.get('sourceVersion', None) == f'pr/{pr["number"]}']
            log.debug(f'Statuses: {statuses}')
            if len(statuses) == 0:
                log.error(f'No build have been triggered for PR: {pr["number"]} within {wait} secs')
                sys.exit(1)
        return statuses

    @pytest.mark.dependency()
    def test_merge_lock_codebuild(self, merge_lock_status):        
        log.info('Assert build succeeded')
        assert all(status == 'SUCCEEDED' for status in merge_lock_status)

    @pytest.mark.dependency(depends=["test_merge_lock_codebuild"])
    def test_merge_lock_pr_status(self, repo, pr):
        log.info('Assert PR head commit status is successful')
        log.debug(f'PR head commit: {pr["head_commit_id"]}')
        
        assert repo.get_commit(pr["head_commit_id"]).get_statuses()[0].state == 'success'

    @pytest.fixture(scope='class')
    def trigger_sf_status(self, cb, mut_output, merge_pr):
        id = cb.list_builds_for_project(
            projectName=mut_output['codebuild_trigger_sf_name'],
            sortOrder='DESCENDING'
        )['ids'][0]
        
        status = 'IN_PROGRESS'
        log.info('Waiting on trigger sf Codebuild execution to finish')
        while status == 'IN_PROGRESS':
            time.sleep(60)
            status = cb.batch_get_builds(ids=[id])['builds'][0]['buildStatus']
            log.debug(f'Status: {status}')
        
        return status

    @pytest.mark.dependency(depends=["test_merge_lock_pr_status"])
    def test_trigger_sf_codebuild(self, trigger_sf_status):

        log.info('Assert build succeeded')
        assert trigger_sf_status == 'SUCCEEDED'
    
    @pytest.mark.dependency(depends=["test_trigger_sf_codebuild"])
    def test_executions_exists(self, conn, scenario, pr):
        with conn.cursor() as cur:
            cur.execute(sql.SQL("SELECT array_agg(cfg_path::TEXT) FROM executions WHERE commit_id = {}").format(pr["head_commit_id"]))
            ids = cur.fetchone()[0]
        if ids == None:
            target_execution_ids = []
        else:
            target_execution_ids = [id for id in ids]
        
        assert len(scenario['executions']) == len(target_execution_ids)

    @pytest.fixture(scope="class")
    def execution_record(self, conn, request, pr, trigger_sf_status):
        with conn.cursor() as cur:
            cur.execute(sql.SQL("SELECT 1 FROM executions WHERE commit_id = {} AND status = 'running'").format(pr["head_commit_id"]))
            record = cur.fetchone()[0]
        yield record

    # @pytest.mark.dependency(depends=["test_executions_exists"])
    def test_sf_execution_running(self, mut_output, sf, execution_record, scenario):
        executions = sf.list_executions(
            stateMachineArn=mut_output['state_machine_arn'],
            statusFilter='RUNNING'
        )['executions']
        running_ids = [execution['name'] for execution in executions]

    #     assert execution_record['execution_id'] in running_ids
        
    # def test_approval_request(cfg, s3):
    #     #while running executions' approval response is not finished, check if s3 bucket received requests
    #     obj = s3.get_object(Bucket=os.environ['TESTING_BUCKET_NAME'], Key=os.environ['TESTING_EMAIL_S3_KEY'])
    #     action_url = json.loads(obj['Body'].read())[cfg['action']]
        
    #     out = subprocess.run(["ping", "-c", action_url], capture_output=True, check=True)

    # def test_applied_changes(self, execution):
    #     # run tg plan -detailed-exitcode and assert return code is == 0
    #     pass

    # def test_cw_event_sent(self):
    #     pass
