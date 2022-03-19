from heapq import merge
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
import git
import timeout_decorator
import random
import string
from pytest_dependency import depends
import boto3
from pprint import pformat
import re
import tftest
import requests
import aurora_data_api

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class Integration:

    @pytest.fixture(scope='class')
    def case_param(self, request):
        return request.param

    @pytest.fixture(scope='class')
    def tested_executions(self):
        ids = []
        
        def _add_id(id=None):
            if id != None:
                ids.append(id)
            
            return ids

        yield _add_id

        ids = []

    @pytest.fixture(scope='class', autouse=True)
    def pr(self, request, repo, case_param, git_repo, merge_pr, tmp_path_factory):
        os.environ['BASE_REF'] = 'master'
        if 'revert_ref' not in case_param:
            base_commit = repo.get_branch(os.environ['BASE_REF'])
            head_ref = repo.create_git_ref(ref='refs/heads/' + case_param['head_ref'], sha=base_commit.commit.sha)
            elements = []
            for dir, cfg in case_param['executions'].items():
                if 'pr_files_content' in cfg:
                    for content in cfg['pr_files_content']:
                        filepath = dir + '/' + ''.join(random.choice(string.ascii_lowercase) for _ in range(8)) + '.tf'
                        log.debug(f'Creating file: {filepath}')
                        blob = repo.create_git_blob(content, "utf-8")
                        elements.append(github.InputGitTreeElement(path=filepath, mode='100644', type='blob', sha=blob.sha))

            head_sha = repo.get_branch(case_param['head_ref']).commit.sha
            base_tree = repo.get_git_tree(sha=head_sha)
            tree = repo.create_git_tree(elements, base_tree)
            parent = repo.get_git_commit(sha=head_sha)
            commit_id = repo.create_git_commit("scenario pr changes", tree, [parent]).sha
            head_ref.edit(sha=commit_id)

            
            log.info('Creating PR')
            pr = repo.create_pull(title=f"test-{case_param['head_ref']}", body=f'test PR class: {request.cls.__name__}', base=os.environ['BASE_REF'], head=case_param['head_ref'])
            
            log.debug(f'head ref commit: {commit_id}')
            log.debug(f'pr commits: {pr.commits}')

            yield {
                'number': pr.number,
                'head_commit_id': commit_id,
                'base_ref': os.environ['BASE_REF'],
                'head_ref': case_param['head_ref']
            }

        else:
            log.info(f'Creating PR to revert changes from PR named: {case_param["revert_ref"]}')
            dir = str(tmp_path_factory.mktemp('scenario-repo-revert'))

            log.info(f'Creating revert branch: {case_param["head_ref"]}')
            base_commit = repo.get_branch(os.environ['BASE_REF'])
            head_ref = repo.create_git_ref(ref='refs/heads/' + case_param['head_ref'], sha=base_commit.commit.sha)

            git_repo = git.Repo.clone_from(f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git', dir, branch=case_param['head_ref'])
            
            merge_commit = merge_pr()
            log.debug(f'Merged Commits: {merge_commit}')
            log.debug(f'Reverting merge commit: {merge_commit[case_param["revert_ref"]].sha}')
            git_repo.git.revert('-m', '1', '--no-commit', str(merge_commit[case_param["revert_ref"]].sha))
            git_repo.git.commit('-m', 'Revert PR changes within PR case')
            git_repo.git.push('origin')

            log.debug('Creating PR')
            pr = repo.create_pull(title=f'Revert {case_param["revert_ref"]}', body='Rollback PR', base=os.environ['BASE_REF'], head=case_param['head_ref'])

            yield {
                'number': pr.number,
                'head_commit_id': git_repo.head.object.hexsha,
                'base_ref': os.environ['BASE_REF'],
                'head_ref': case_param['head_ref']
            }

        log.info('Removing PR head ref branch')
        head_ref.delete()
        
        try:
            log.info('Closing PR')
            pr.edit(state='closed')
        except Exception:
            pass

    def get_execution_history(self, sf, arn, id):
        execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=arn)['executions'] if execution['name'] == id][0]

        return sf.get_execution_history(executionArn=execution_arn, includeExecutionData=True)['events']
    

    def get_build_status(self, client, name, ids=[], filters={}, sf_execution_filter={}):
        
        statuses = ['IN_PROGRESS']
        wait = 30

        time.sleep(wait)

        if len(ids) == 0:
            ids = client.list_builds_for_project(
                projectName=name,
                sortOrder='DESCENDING'
            )['ids']

            if len(ids) == 0:
                log.error(f'No builds have runned for project: {name}')
                sys.exit(1)
            
            log.debug(f'Build Filters:\n{filters}')
            log.debug(f'Step Function Execution Output Filters:\n{sf_execution_filter}')
            for build in client.batch_get_builds(ids=ids)['builds']:
                skip_sf_filter = False
                for key, value in filters.items():
                    if build.get(key, None) != value:
                        ids.remove(build['id'])
                        skip_sf_filter = True
                        break
                
                if skip_sf_filter:
                    continue
                
                if sf_execution_filter != {}:
                    sf_execution_env_var = {}
                    for env_var in build['environment']['environmentVariables']:
                        if env_var['name'] == 'EXECUTION_OUTPUT':
                            sf_execution_env_var = json.loads(env_var['value'])
                    
                    for key, value in sf_execution_filter.items():
                        if (key, value) not in sf_execution_env_var.items():
                            ids.remove(build['id'])
                            break
                
            if len(ids) == 0:
                log.error(f'No builds have met provided filters')
                sys.exit(1)

        log.debug(f'Getting build statuses for the following IDs:\n{ids}')
        while 'IN_PROGRESS' in statuses:
            time.sleep(wait)
            statuses = []
            for build in client.batch_get_builds(ids=ids)['builds']:
                statuses.append(build['buildStatus'])
    
        return statuses
         
    @timeout_decorator.timeout(120)
    @pytest.mark.dependency()
    def test_merge_lock_pr_status(self, request, repo, mut_output, pr):
        """Assert PR's head commit ID has a successful merge lock status"""
        wait = 3

        statuses = repo.get_commit(pr["head_commit_id"]).get_statuses()
        while statuses.totalCount == 0:
            log.debug(f'Waiting {wait} seconds')
            time.sleep(wait)

            statuses = repo.get_commit(pr["head_commit_id"]).get_statuses()
        
        log.info('Assert PR head commit status is successful')
        log.debug(f'PR head commit: {pr["head_commit_id"]}')

        assert statuses.totalCount == 1
        assert statuses[0].state == 'success'
        
    @timeout_decorator.timeout(300)
    @pytest.mark.dependency()
    def test_trigger_sf_codebuild(self, request, case_param, mut_output, merge_pr, pr, cb):
        """Assert scenario's associated trigger_sf codebuild was successful"""
        depends(request, [f'{request.cls.__name__}::test_merge_lock_pr_status[{request.node.callspec.id}]'])

        merge_pr(pr['base_ref'], pr['head_ref'])

        log.info('Waiting on trigger sf Codebuild execution to finish')

        status = self.get_build_status(cb, mut_output["codebuild_trigger_sf_name"], filters={'sourceVersion': f'pr/{pr["number"]}'})[0]
        
        if case_param.get('expect_failed_trigger_sf', False):
            log.info('Assert build failed')
            assert status == 'FAILED'
        else:
            log.info('Assert build succeeded')
            assert status == 'SUCCEEDED'

    @pytest.mark.dependency()
    def test_deploy_execution_records_exist(self, request, conn, case_param, pr):
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
        conn.commit()

        if ids == None:
            target_execution_ids = []
        else:
            target_execution_ids = [id for id in ids]
        
        log.debug(f'Commit execution IDs:\n{target_execution_ids}')

        assert len(case_param['executions']) == len(target_execution_ids)
        
    @pytest.fixture(scope="class")
    def target_execution(self, conn, pr, tested_executions, case_param):
        
        log.debug(f'Already tested execution IDs:\n{tested_executions()}')
        with conn.cursor() as cur:
            cur.execute(f"""
                SELECT *
                FROM executions 
                WHERE commit_id = '{pr["head_commit_id"]}'
                AND "status" IN ('running', 'aborted', 'failed')
                AND NOT (execution_id = ANY (ARRAY{tested_executions()}::TEXT[]))
                LIMIT 1
            """)
            results = cur.fetchone()
        conn.commit()

        record = {}
        if results != None:
            row = [value for value in results]
            for i, description in enumerate(cur.description):
                record[description.name] = row[i]

            log.debug(f'Target Execution Record:\n{pformat(record)}')
            yield record
        else:
            pytest.skip('No new running or finished execution records')

        log.debug('Adding execution ID to tested executions list')
        if record != {}:
            tested_executions(record['execution_id'])

    @pytest.fixture(scope="class")
    def action(self, target_execution, case_param):
        if target_execution['is_rollback']:
            return case_param['executions'][target_execution['cfg_path']]['actions']['rollback_providers']
        else:
            return case_param['executions'][target_execution['cfg_path']].get('actions', {}).get('deploy', None)
    
    @pytest.mark.dependency()
    def test_sf_execution_aborted(self, request, sf, target_execution, mut_output, case_param):

        target_execution_param = request.node.callspec.id.split('-')[-1]
        if target_execution_param != '0':
            depends(request, [
                f"{request.cls.__name__}::test_deploy_execution_records_exist[{request.node.callspec.id.rsplit('-', 1)[0]}]",
                # depends on previous target_execution param's cw event trigger sf build finished status
                f"{request.cls.__name__}::test_cw_event_trigger_sf[{re.sub(r'^.+?-', f'{int(target_execution_param) - 1}-', request.node.callspec.id)}]"
            ])
        else:
            depends(request, [f"{request.cls.__name__}::test_deploy_execution_records_exist[{request.node.callspec.id.rsplit('-', 1)[0]}]"])

        if target_execution['status'] != 'aborted':
            pytest.skip('Execution approval action is not set to `aborted`')

        try:
            execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]
        except IndexError:
            log.info('Execution record status was set to aborted before associated Step Function execution was created')
            assert case_param['sf_execution_exists'] == False
        else:
            assert sf.describe_execution(executionArn=execution_arn)['status'] == 'ABORTED'

    @pytest.mark.dependency()
    def test_sf_execution_exists(self, request, mut_output, sf, target_execution):
        """Assert execution record has an associated Step Function execution"""

        depends(request, [f"{request.cls.__name__}::test_deploy_execution_records_exist[{request.node.callspec.id.rsplit('-', 1)[0]}]"])

        if target_execution['status'] == 'aborted':
            pytest.skip('Execution approval action is set to `aborted`')

        execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]

        assert sf.describe_execution(executionArn=execution_arn)['status'] in ['RUNNING', 'SUCCEEDED', 'FAILED', 'TIMED_OUT']

    @pytest.mark.dependency()
    def test_terra_run_plan_codebuild(self, request, mut_output, sf, cb, target_execution):
        """Assert running execution record has a running Step Function execution"""
        depends(request, [f'{request.cls.__name__}::test_sf_execution_exists[{request.node.callspec.id}]'])

        log.info(f'Testing Plan Task')

        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        status = None
        for event in events:
            if event['type'] == 'TaskSubmitted' and event['taskSubmittedEventDetails']['resourceType'] == 'codebuild':
                plan_build_id = json.loads(event['taskSubmittedEventDetails']['output'])['Build']['Id']
                status = self.get_build_status(cb, mut_output["codebuild_terra_run_name"], ids=[plan_build_id])[0]
                break
        
        if status == None:
            pytest.fail('Task was not submitted')

        assert status == 'SUCCEEDED'

    @timeout_decorator.timeout(30)
    @pytest.mark.dependency()
    def test_approval_request(self, request, sf, mut_output, target_execution):
        depends(request, [f'{request.cls.__name__}::test_terra_run_plan_codebuild[{request.node.callspec.id}]'])

        submitted = False
        wait = 5
        while not submitted:
            log.debug(f'Giving Step Function {wait} to submit approval request')
            time.sleep(wait)
            
            events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

            for event in events:
                if event['type'] == 'TaskSubmitted' and event['taskSubmittedEventDetails']['resource'] == 'invoke.waitForTaskToken':
                    submitted = True
                    out = json.loads(event['taskSubmittedEventDetails']['output'])

        assert out['StatusCode'] == 200

    @pytest.mark.dependency()
    def test_approval_response(self, request, sf, action, mut_output, target_execution):
        depends(request, [f'{request.cls.__name__}::test_approval_request[{request.node.callspec.id}]'])
        log.info('Testing Approval Task')

        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            if event['type'] == 'TaskScheduled' and event['taskScheduledEventDetails']['resource'] == 'invoke.waitForTaskToken':
                task_token = json.loads(event['taskScheduledEventDetails']['parameters'])['Payload']['PathApproval']['TaskToken']

        approval_url = f'{mut_output["approval_url"]}?ex={target_execution["execution_id"]}&sm={mut_output["state_machine_arn"]}&taskToken={task_token}'
        log.debug(f'Approval URL: {approval_url}')

        body = {
            'action': action,
            'recipient': mut_output['voters']
        }

        log.debug(f'Request Body:\n{body}')

        response = requests.post(approval_url, data=body)
        log.debug(f'Response:\n{response}')

        assert json.loads(response.text)['statusCode'] == 302

    @pytest.mark.dependency()
    def test_approval_denied(self, request, sf, target_execution, mut_output, action):
        depends(request, [f'{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]'])

        if action == 'approve':
            pytest.skip('Approval action is set to `approve`')

        log.debug(f'Execution ID: {target_execution["execution_id"]}')
        state = None
        out = None
        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            if event['type'] == 'PassStateEntered':
                state = event
            elif event['type'] == 'PassStateExited':
                if event['stateExitedEventDetails']['name'] == 'Reject':
                    out = json.loads(event['stateExitedEventDetails']['output'])

        log.debug(f'Rejection State Output:\n{pformat(out)}')
        assert state is not None
        assert out['status'] == 'failed'

    @pytest.mark.dependency()
    def test_terra_run_deploy_codebuild(self, request, mut_output, sf, cb, target_execution, action):
        """Assert running execution record has a running Step Function execution"""
        depends(request, [f'{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]'])

        if action == 'reject':
            pytest.skip('Approval action is set to `reject`')

        log.info(f'Testing Deploy Task')

        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            #TODO: differentiate between plan/deploy tasks
            if event['type'] == 'TaskSubmitted' and event['taskSubmittedEventDetails']['resourceType'] == 'codebuild':
                plan_build_id = json.loads(event['taskSubmittedEventDetails']['output'])['Build']['Id']
                status = self.get_build_status(cb, mut_output["codebuild_terra_run_name"], ids=[plan_build_id])[0]

        assert status == 'SUCCEEDED'
    
    @pytest.mark.dependency()
    def test_sf_execution_status(self, request, mut_output, sf, target_execution, action):

        if action == 'approve':
            depends(request, [f'{request.cls.__name__}::test_terra_run_deploy_codebuild[{request.node.callspec.id}]'])
        else:
            depends(request, [f'{request.cls.__name__}::test_approval_denied[{request.node.callspec.id}]'])

        execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]
        response = sf.describe_execution(executionArn=execution_arn)
        assert response['status'] == 'SUCCEEDED'

    @pytest.mark.dependency()
    def test_cw_event_trigger_sf(self, request, cb, mut_output, target_execution, action):
        depends(request, [f'{request.cls.__name__}::test_sf_execution_status[{request.node.callspec.id}]'])
        status = self.get_build_status(cb, mut_output['codebuild_trigger_sf_name'], filters={'initiator': mut_output['cw_rule_initiator']}, sf_execution_filter={'execution_id': target_execution['execution_id']})[0]

        if action == 'reject' and target_execution['is_rollback'] == 'true':
            assert status == 'FAILED'
        else:
            assert status == 'SUCCEEDED'

    @pytest.mark.dependency()
    def test_rollback_providers_executions_exists(self, request, conn, case_param, pr, action, target_execution):
        """Assert that all expected scenario directories are within executions table"""
        depends(request, [f'{request.cls.__name__}::test_cw_event_trigger_sf[{request.node.callspec.id}]'])

        if target_execution['is_rollback'] != 'true' and action != 'reject':
            pytest.skip('Expected approval action is not set to `reject` so rollback provider executions will not be created')
        with conn.cursor() as cur:
            cur.execute(f"""
            SELECT array_agg(execution_id::TEXT)
            FROM executions 
            WHERE commit_id = '{pr["head_commit_id"]}'
            AND is_rollback = true
            AND cardinality(new_providers) > 0
            """
            )
            ids = cur.fetchone()[0]
        conn.commit()

        if ids == None:
            target_execution_ids = []
        else:
            target_execution_ids = [id for id in ids]
        
        log.debug(f'Commit execution IDs:\n{target_execution_ids}')

        expected_execution_count = len([1 for cfg in case_param['executions'].values() if 'rollback_providers' in cfg.get('actions', {})])

        assert expected_execution_count == len(target_execution_ids)