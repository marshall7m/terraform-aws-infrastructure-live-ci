import subprocess
import psycopg2
from psycopg2 import sql
import pytest
from unittest.mock import patch
import os
import logging
import sys
from psycopg2.sql import SQL
import pandas.io.sql as psql
from helpers.utils import TestSetup
import shutil
import uuid
import json
import time
import boto3
import git
import github

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.fixture(scope='session')
def cb():
    return boto3.client('codebuild')

@pytest.fixture(scope='module')
def gh():
    return github.Github(os.environ['GITHUB_TOKEN'])

@pytest.fixture(scope='module')
def repo(gh):
    repo = gh.get_user().create_repo(f'mut-terraform-aws-infrastructure-merge-lock-{uuid.uuid4()}', auto_init=True)
    os.environ['REPO_FULL_NAME'] = repo.full_name
    repo.edit(default_branch='master')

    yield repo
    repo.delete()
test_null_resource = """
provider "null" {}

resource "null_resource" "this" {}
"""

test_output = """
output "{random}" {{
    value = "{random}"
}}
"""

# list of PRs with directory to create test files within
@pytest.fixture(scope='module', params=[
    {
        'directory_dependency/dev-account/us-west-2/env-one/doo': test_null_resource
    }
])
def pr_head_commit(repo, request):
    os.environ['BASE_REF'] = 'master'
    os.environ['HEAD_REF'] = f'feature-{uuid.uuid4()}'

    base_commit = repo.get_branch(os.environ['BASE_REF'])
    head_ref = repo.create_git_ref(ref='refs/heads/' + os.environ['HEAD_REF'], sha=base_commit.commit.sha)
    elements = []
    for path, content in request.param.items():
        blob = repo.create_git_blob(content, "utf-8")
        elements.append(github.InputGitTreeElement(path=path, mode='100644', type='blob', sha=blob.sha))

    head_sha = repo.get_branch(os.environ['HEAD_REF']).commit.sha
    base_tree = repo.get_git_tree(sha=head_sha)
    tree = repo.create_git_tree(elements, base_tree)
    parent = repo.get_git_commit(sha=head_sha)
    commit_id = repo.create_git_commit("commit_message", tree, [parent]).sha
    head_ref.edit(sha=commit_id)

    repo.create_pull(title=f"test-{os.environ['HEAD_REF']}", body='test', base=os.environ['BASE_REF'], head=os.environ['HEAD_REF'])

    yield commit_id

@pytest.fixture(scope='module')
def merge_lock_status(cb, pr_head_commit):
    id = cb.list_builds_for_project(
        projectName=os.environ['MERGE_LOCK_CODEBUILD_NAME'],
        sortOrder='DESCENDING'
    )['ids'][0]
    
    status = 'IN_PROGRESS'
    log.info('Waiting on merge lock Codebuild execution to finish')
    while status == 'IN_PROGRESS':
        time.sleep(60)
        status = cb.batch_get_builds(ids=[id])['builds'][0]['buildStatus']
        log.debug(f'Status: {status}')
    
    return status

@pytest.fixture(scope='module')
def merge_pr(repo, merge_lock_status):
    return repo.merge(os.environ['BASE_REF'], os.environ['HEAD_REF'])

@pytest.fixture(scope='module')
def trigger_sf_status():
    id = cb.list_builds_for_project(
        projectName=os.environ['TRIGGER_SF_CODEBUILD_NAME'],
        sortOrder='DESCENDING'
    )['ids'][0]
    
    status = 'IN_PROGRESS'
    log.info('Waiting on merge lock Codebuild execution to finish')
    while status == 'IN_PROGRESS':
        time.sleep(60)
        status = cb.batch_get_builds(ids=[id])['builds'][0]['buildStatus']
        log.debug(f'Status: {status}')
    
    return status

@pytest.fixture(scope='module')
def target_execution_ids(conn, trigger_sf_status):
    with conn.cursor() as cur:
        cur.execute(sql.SQL("SELECT array_agg(execution_id::TEXT) FROM executions WHERE commit_id = {}").format(pr_head_commit))
        ids = cur.fetchone()[0]
    if ids == None:
        target_execution_ids = []
    else:
        target_execution_ids = [id for id in ids]
    
    return target_execution_ids

@pytest.mark.dependency()
def test_merge_lock_codebuild(merge_lock_status):
    log.info('Assert build succeeded')
    assert merge_lock_status == 'SUCCEEDED'

@pytest.mark.dependency(depends=["test_merge_lock_codebuild"])
def test_merge_lock_pr_status(repo, pr_head_commit, merge_lock_status):
    log.info('Assert PR head commit status is successful')
    log.debug(f'PR head commit: {pr_head_commit}')
    
    assert repo.get_commit(pr_head_commit).get_statuses()[0].state == 'success'

@pytest.mark.dependency()
def test_trigger_sf_codebuild(trigger_sf_status):
    log.info('Assert build succeeded')
    assert trigger_sf_status == 'SUCCEEDED'

#TODO: Figure out how to pass flatten list of target cfg_paths in relation to tg dependency tree
# OPTION A: 
# create get_running_execution() fixture factory that gets 1 running execution cfg_path to run test on
# parametrize class with the range of 0 to length of total target execution ids

@pytest.mark.parametrize("cfg_path", [])
class TestSF:

    def test_sf_execution_running(self, sf, id):
        executions = sf.list_executions(
            stateMachineArn=os.environ['STATE_MACHINE_ARN'],
            statusFilter='RUNNING'
        )['executions']
        running_ids = [execution['name'] for execution in executions]

        assert id in running_ids
        
    # def test_approval_request(cfg, s3):
    #     #while running executions' approval response is not finished, check if s3 bucket received requests
    #     obj = s3.get_object(Bucket=os.environ['TESTING_BUCKET_NAME'], Key=os.environ['TESTING_EMAIL_S3_KEY'])
    #     action_url = json.loads(obj['Body'].read())[cfg['action']]
        
    #     out = subprocess.run(["ping", "-c", action_url], capture_output=True, check=True)

    def test_applied_changes(self, cfg_path):
        # run tg plan -detailed-exitcode and assert return code is == 0
        pass

    def test_cw_event_sent():
        pass