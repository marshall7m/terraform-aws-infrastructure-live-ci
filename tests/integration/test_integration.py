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
from pprint import pformat
import re
import tftest
import requests
import aurora_data_api


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TestIntegration:

    @pytest.fixture(scope='class', autouse=True)
    def tested_executions(self):
        ids = []
        
        def _add_id(id=None):
            if id != None:
                ids.append(id)
            
            return ids

        yield _add_id

        ids = []

    @pytest.fixture(scope='class', autouse=True)
    def truncate_executions(self, mut_output):
        #table setup is within tf module
        #yielding none to define truncation as pytest teardown logic
        yield None
        log.info('Truncating executions table')
        with aurora_data_api.connect(
            aurora_cluster_arn=mut_output['metadb_arn'],
            secret_arn=mut_output['metadb_secret_manager_master_arn'],
            database=mut_output['metadb_name'],
            #recommended for DDL statements
            continue_after_timeout=True
        ) as conn:
            with conn.cursor() as cur:
                cur.execute("TRUNCATE executions")

    @pytest.fixture(scope='class', autouse=True)
    def abort_hanging_sf_executions(self, sf, mut_output):
        yield None

        log.info('Stopping step function execution if left hanging')
        execution_arns = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'], statusFilter='RUNNING')['executions']]

        for arn in execution_arns:
            log.debug(f'ARN: {arn}')

            sf.stop_execution(
                executionArn=arn,
                error='IntegrationTestsError',
                cause='Failed integrations tests prevented execution from finishing'
            )

    @pytest.fixture(scope='class', autouse=True)
    def destroy_scenario_tf_resources(self, cb, conn, mut_output):

        yield None
        log.info('Destroying Terraform provisioned resources from test repository')

        with conn.cursor() as cur:
            cur.execute(f"""
            SELECT account_name, account_path, deploy_role_arn
            FROM account_dim 
            """
            )

            accounts = []
            for result in cur.fetchall():
                record = {}
                for i, description in enumerate(cur.description):
                    record[description.name] = result[i]
                accounts.append(record)
        conn.commit()
            
        log.debug(f'Accounts:\n{pformat(accounts)}')

        ids = []
        log.info("Starting account-level terraform destroy builds")
        for account in accounts:
            log.debug(f'Account Name: {account["account_name"]}')

            response = cb.start_build(
                projectName=mut_output['codebuild_terra_run_name'],
                environmentVariablesOverride=[
                    {
                        'name': 'TG_COMMAND',
                        'type': 'PLAINTEXT',
                        'value': f'terragrunt run-all destroy --terragrunt-working-dir {account["account_path"]} -auto-approve'
                    },
                    {
                        'name': 'ROLE_ARN',
                        'type': 'PLAINTEXT',
                        'value': account['deploy_role_arn']
                    }
                ]
            )

            ids.append(response['build']['id'])
        
        log.info('Waiting on destroy builds to finish')
        statuses = self.get_build_status(cb, mut_output['codebuild_terra_run_name'], ids=ids)

        log.info(f'Finished Statuses:\n{statuses}')

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
    
    def get_execution_history(self, sf, arn, id):
        execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=arn)['executions'] if execution['name'] == id][0]

        return sf.get_execution_history(executionArn=execution_arn, includeExecutionData=True)['events']

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
        return self.get_build_status(cb, mut_output["codebuild_merge_lock_name"], filters={'sourceVersion': f'pr/{pr["number"]}'})

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

    def get_build_status(self, client, name, ids=[], filters={}):

        statuses = ['IN_PROGRESS']
        wait = 60

        while 'IN_PROGRESS' in statuses:
            time.sleep(wait)
            if len(ids) == 0:
                ids = client.list_builds_for_project(
                    projectName=name,
                    sortOrder='DESCENDING'
                )['ids']

            if len(ids) == 0:
                log.error(f'No builds have runned for project: {name}')
                sys.exit(1)
            statuses = []
            for build in client.batch_get_builds(ids=ids)['builds']:
                for key, value in filters.items():
                    if build.get(key, None) != value:
                        break
                else:
                    statuses.append(build['buildStatus'])
    
        return statuses

    @pytest.fixture(scope='class')
    @timeout_decorator.timeout(300)
    def trigger_sf_status(self, cb, mut_output, pr, merge_pr):
        log.info('Waiting on trigger sf Codebuild execution to finish')

        return self.get_build_status(cb, mut_output["codebuild_trigger_sf_name"], filters={'sourceVersion': f'pr/{pr["number"]}'})

    @pytest.mark.dependency()
    def test_trigger_sf_codebuild(self, request, trigger_sf_status):
        """Assert scenario's associated trigger_sf codebuild was successful"""
        depends(request, [f'{request.cls.__name__}::test_merge_lock_pr_status[{request.node.callspec.id}]'])

        log.info('Assert build succeeded')
        assert len(trigger_sf_status) == 1
        assert trigger_sf_status[0] == 'SUCCEEDED'
    
    @pytest.mark.dependency()
    def test_execution_records_exists(self, request, conn, scenario, pr):
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
        assert len(scenario['executions']) == len(target_execution_ids)
    
    @pytest.fixture(scope="class")
    def target_execution(self, conn, pr, request, sf, mut_output, cb, scenario, tested_executions):

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
        else:
            log.error('Expected target execution record was not found')
            sys.exit(1)

        log.debug(f'Target Execution Record:\n{pformat(record)}')
        yield record

        log.debug('Adding execution ID to tested executions list')
        tested_executions(record['execution_id'])
    
    @pytest.mark.dependency()
    def test_sf_execution_aborted(self, request, sf, target_execution, mut_output):
        depends(request, [f"{request.cls.__name__}::test_execution_records_exists[{re.sub(r'^.+?-', '', request.node.callspec.id)}]"])

        if target_execution['status'] != 'aborted':
            pytest.skip()

        try:
            execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]
        except IndexError:
            log.info('Executino record status was set to aborted before associated Step Function execution was created')
        else:
            assert sf.describe_execution(executionArn=execution_arn)['status'] == 'ABORTED'

    @pytest.mark.dependency()
    def test_sf_execution_exists(self, request, mut_output, sf, target_execution, scenario):
        """Assert execution record has an associated Step Function execution"""

        depends(request, [f"{request.cls.__name__}::test_execution_records_exists[{re.sub(r'^.+?-', '', request.node.callspec.id)}]"])

        if target_execution['status'] == 'aborted':
            pytest.skip()

        execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]

        assert sf.describe_execution(executionArn=execution_arn)['status'] in ['RUNNING', 'SUCCEEDED', 'FAILED', 'TIMED_OUT']

    @pytest.mark.dependency()
    def test_terra_run_plan_codebuild(self, request, mut_output, sf, cb, target_execution, scenario):
        """Assert running execution record has a running Step Function execution"""
        depends(request, [f'{request.cls.__name__}::test_sf_execution_exists[{request.node.callspec.id}]'])

        log.info(f'Testing Plan Task')

        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            if event['type'] == 'TaskSubmitted' and event['taskSubmittedEventDetails']['resourceType'] == 'codebuild':
                plan_build_id = json.loads(event['taskSubmittedEventDetails']['output'])['Build']['Id']
                status = self.get_build_status(cb, mut_output["codebuild_terra_run_name"], ids=[plan_build_id])[0]

        assert status == 'SUCCEEDED'

    @pytest.mark.dependency()
    def test_approval_request(self, request, sf, scenario, mut_output, target_execution):
        depends(request, [f'{request.cls.__name__}::test_terra_run_plan_codebuild[{request.node.callspec.id}]'])
    
        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            if event['type'] == 'TaskSubmitted' and event['taskSubmittedEventDetails']['resource'] == 'invoke.waitForTaskToken':
                out = json.loads(event['taskSubmittedEventDetails']['output'])

        assert out['StatusCode'] == 200

    @pytest.mark.dependency()
    def test_approval_response(self, request, sf, scenario, mut_output, target_execution):
        depends(request, [f'{request.cls.__name__}::test_approval_request[{request.node.callspec.id}]'])
        log.info('Testing Approval Task')

        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            if event['type'] == 'TaskScheduled' and event['taskScheduledEventDetails']['resource'] == 'invoke.waitForTaskToken':
                task_token = json.loads(event['taskScheduledEventDetails']['parameters'])['Payload']['PathApproval']['TaskToken']

        approval_url = f'{mut_output["approval_url"]}?ex={target_execution["execution_id"]}&sm={mut_output["state_machine_arn"]}&taskToken={task_token}'
        log.debug(f'Approval URL: {approval_url}')

        body = {
            'action': scenario['executions'][target_execution['cfg_path']]['action'],
            'recipient': mut_output['voters']
        }

        log.debug(f'Request Body:\n{body}')

        response = requests.post(approval_url, data=body)
        log.debug(f'Response:\n{response}')

        assert json.loads(response.text)['statusCode'] == 302

    @pytest.mark.dependency()
    def test_approval_denied(self, request, sf, target_execution, mut_output, scenario):
        depends(request, [f'{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]'])

        if scenario['executions'][target_execution['cfg_path']]['action'] == 'approve':
            pytest.skip()
        
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
    def test_terra_run_deploy_codebuild(self, request, mut_output, sf, cb, target_execution, scenario):
        if scenario['executions'][target_execution['cfg_path']]['action'] == 'reject':
            pytest.skip()
        """Assert running execution record has a running Step Function execution"""
        depends(request, [f'{request.cls.__name__}::test_approval_response[{request.node.callspec.id}]'])

        log.info(f'Testing Deploy Task')

        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            if event['type'] == 'TaskSubmitted' and event['taskSubmittedEventDetails']['resourceType'] == 'codebuild':
                plan_build_id = json.loads(event['taskSubmittedEventDetails']['output'])['Build']['Id']
                status = self.get_build_status(cb, mut_output["codebuild_terra_run_name"], ids=[plan_build_id])[0]

        assert status == 'SUCCEEDED'
    
    @pytest.mark.dependency()
    def test_sf_execution_status(self, request, mut_output, sf, target_execution, scenario, tested_executions):

        if scenario['executions'][target_execution['cfg_path']]['action'] == 'approve':
            depends(request, [f'{request.cls.__name__}::test_terra_run_deploy_codebuild[{request.node.callspec.id}]'])
        else:
            depends(request, [f'{request.cls.__name__}::test_approval_denied[{request.node.callspec.id}]'])

        execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]
        response = sf.describe_execution(executionArn=execution_arn)
        assert response['status'] == 'SUCCEEDED'

    @pytest.mark.dependency()
    def test_cw_event_sent(self, request, cb, mut_output, scenario, target_execution):
        depends(request, [f'{request.cls.__name__}::test_sf_execution_status[{request.node.callspec.id}]'])
        status = self.get_build_status(cb, mut_output['codebuild_trigger_sf_name'], filters={'initiator': mut_output['cw_rule_initiator']})[0]

        assert status == 'SUCCEEDED'