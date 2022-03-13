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
from pytest_lazyfixture import lazy_fixture


# def pytest_collection_modifyitems(config, items):
    # """Rearrange testing order so that rollback test classes are always executed after PR test classes"""
    # config.fromdictargs({'foo': 'doo'}, 'zoo')
    # updated = []
    # scenarios = [item.nodeid.split('::')[1] for item in items]
    # log.debug(f'Scenario Class Names:\n{scenarios}')

    # for item in items:
    #     for name in scenarios:
    #         main = []
    #         rollbacks = []
    #         if item.nodeid.startswith(f'tests/integration/test_scenarios.py::{name}::TestRollbackPR'):
    #             rollbacks.append(item)
    #         else:
    #             main.append(item)
    #     updated.extend(main.extend(rollbacks))
    # items[:] = updated

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

@pytest.mark.usefixtures('stage', 'scenario_param')
class TestIntegration:

    @pytest.fixture(scope='class', autouse=True)
    def stage(self, request):
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

    @pytest.fixture(scope='module', autouse=True)
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

    @pytest.fixture(scope='class')
    def merge_pr(self, repo, git_repo):
        
        merge_commits = []

        def _merge(base_ref=None, head_ref=None):
            if base_ref != None and head_ref != None:
                log.info('Merging PR')
                merge_commits.append(repo.merge(base_ref, head_ref))

            return merge_commits

        yield _merge
        
        log.info(f'Removing PR changes from branch: {git_repo.git.branch_name}')

        log.debug('Pulling remote changes')
        git_repo.git.reset('--hard')
        git_repo.git.pull()

        for commit in reversed(merge_commits):
            log.debug(f'Merge Commit ID: {commit.sha}')
            try:
                git_repo.git.revert('-m', '1', '--no-commit', str(commit.sha))
                git_repo.git.commit('-m', 'Revert scenario PR changes within fixture teardown')
                git_repo.git.push('origin')
            except Exception as e:
                print(e)

    @pytest.fixture(scope='class', autouse=True)
    def pr(self, stage, repo, scenario_param, git_repo, merge_pr, tmp_path_factory):
        if stage == 'deploy':
            os.environ['BASE_REF'] = 'master'
            os.environ['HEAD_REF'] = f'feature-{uuid.uuid4()}'

            base_commit = repo.get_branch(os.environ['BASE_REF'])
            head_ref = repo.create_git_ref(ref='refs/heads/' + os.environ['HEAD_REF'], sha=base_commit.commit.sha)
            elements = []
            for dir, cfg in scenario_param.items():
                if 'pr_file_content' in cfg:
                    for content in cfg['pr_file_content']:
                        filepath = dir + '/' + ''.join(random.choice(string.ascii_lowercase) for _ in range(8)) + '.tf'
                        log.debug(f'Creating file: {filepath}')
                        blob = repo.create_git_blob(content, "utf-8")
                        elements.append(github.InputGitTreeElement(path=filepath, mode='100644', type='blob', sha=blob.sha))

            head_sha = repo.get_branch(os.environ['HEAD_REF']).commit.sha
            base_tree = repo.get_git_tree(sha=head_sha)
            tree = repo.create_git_tree(elements, base_tree)
            parent = repo.get_git_commit(sha=head_sha)
            commit_id = repo.create_git_commit("scenario pr changes", tree, [parent]).sha
            head_ref.edit(sha=commit_id)

            
            log.info('Creating PR')
            pr = repo.create_pull(title=f"test-{os.environ['HEAD_REF']}", body='test', base=os.environ['BASE_REF'], head=os.environ['HEAD_REF'])
            
            log.debug(f'head ref commit: {commit_id}')
            log.debug(f'pr commits: {pr.commits}')

            yield {
                'number': pr.number,
                'head_commit_id': commit_id,
                'base_ref': os.environ['BASE_REF'],
                'head_ref': os.environ['HEAD_REF']
            }

        elif stage == 'rollback_base':
            dir = str(tmp_path_factory.mktemp('scenario-repo-rollback'))

            revert_ref = f'revert-{os.environ["HEAD_REF"]}'

            log.info(f'Creating rollback feature branch: {revert_ref}')
            base_commit = repo.get_branch(os.environ['BASE_REF'])
            head_ref = repo.create_git_ref(ref='refs/heads/' + revert_ref, sha=base_commit.commit.sha)

            git_repo = git.Repo.clone_from(f'https://oauth2:{os.environ["GITHUB_TOKEN"]}@github.com/{os.environ["REPO_FULL_NAME"]}.git', dir, branch=revert_ref)
            
            merge_commit = merge_pr()
            log.debug(f'Merged Commits: {merge_commit}')
            log.debug(f'Reverting merge commit: {merge_commit[0].sha}')
            git_repo.git.revert('-m', '1', '--no-commit', str(merge_commit[0].sha))
            git_repo.git.commit('-m', 'Revert scenario PR changes withing rollback stage')
            git_repo.git.push('origin')

            log.debug('Creating PR')
            pr = repo.create_pull(title=f"Revert {os.environ['HEAD_REF']}", body='Rollback PR', base=os.environ['BASE_REF'], head=revert_ref)

            yield {
                'number': pr.number,
                'head_commit_id': git_repo.head.object.hexsha,
                'base_ref': os.environ['BASE_REF'],
                'head_ref': revert_ref
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

    @pytest.fixture(scope="class", autouse=True)
    def scenario_param(self, request):
        return request.param

    @pytest.mark.dependency()
    @timeout_decorator.timeout(300)
    def test_merge_lock_codebuild(self, request, pr, cb, mut_output, stage):
        """Assert scenario's associated merge_lock codebuild was successful"""

        log.info('Waiting on merge lock Codebuild executions to finish')
        status = self.get_build_status(cb, mut_output["codebuild_merge_lock_name"], filters={'sourceVersion': f'pr/{pr["number"]}'})

        log.info('Assert build succeeded')
        assert all(status == 'SUCCEEDED' for status in status)

    @pytest.mark.dependency()
    def test_merge_lock_pr_status(self, request, repo, pr):
        """Assert PR's head commit ID has a successful merge lock status"""
        depends(request, [f'{request.cls.__name__}::test_merge_lock_codebuild[{request.node.callspec.id}]'])

        log.info('Assert PR head commit status is successful')
        log.debug(f'PR head commit: {pr["head_commit_id"]}')
        
        assert repo.get_commit(pr["head_commit_id"]).get_statuses()[0].state == 'success'

    @timeout_decorator.timeout(300)
    @pytest.mark.dependency()
    def test_trigger_sf_codebuild(self, request, merge_pr, pr, mut_output, cb):
        """Assert scenario's associated trigger_sf codebuild was successful"""
        depends(request, [f'{request.cls.__name__}::test_merge_lock_pr_status[{request.node.callspec.id}]'])

        merge_pr(pr['base_ref'], pr['head_ref'])

        log.info('Waiting on trigger sf Codebuild execution to finish')

        status = self.get_build_status(cb, mut_output["codebuild_trigger_sf_name"], filters={'sourceVersion': f'pr/{pr["number"]}'})[0]

        log.info('Assert build succeeded')
        assert status == 'SUCCEEDED'
    
    @pytest.fixture(scope='class')
    def expected_execution_count(self, scenario_param, stage):
        count_map = {
            'deploy': 0,
            'rollback_providers': 0,
            'rollback_base': 0
        }
        for cfg in scenario_param.values():
            for stage in count_map.keys():
                if stage in cfg['actions']:
                    count_map[stage] += 1
        
        return count_map

    @pytest.mark.dependency()
    def test_execution_records_exists(self, request, conn, stage, expected_execution_count, pr):
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
        log.debug(f'Stages execution count mapping: {expected_execution_count}')

        assert expected_execution_count[stage] == len(target_execution_ids)
        
    @pytest.fixture(scope="class")
    def target_execution(self, request, conn, pr, tested_executions, scenario_param, stage):
        
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

        log.debug('Adding execution ID to tested executions list')
        if record != {}:
            tested_executions(record['execution_id'])

    @pytest.fixture(scope="class")
    def action(self, target_execution, scenario_param, stage):
        if target_execution == {}:
            pytest.skip('No new running or finished execution records')
            # return None
        else:
            return scenario_param[target_execution['cfg_path']]['actions'].get(stage, None)
    
    @pytest.mark.dependency()
    def test_sf_execution_aborted(self, request, sf, target_execution, mut_output):

        target_execution_param = request.node.callspec.id.split('-')[-1]
        if target_execution_param != '0':
            depends(request, [
                f"{request.cls.__name__}::test_execution_records_exists[{request.node.callspec.id.rsplit('-', 1)[0]}]",
                # depends on previous target_execution param's cw event trigger sf build finished status
                f"{request.cls.__name__}::test_cw_event_trigger_sf[{re.sub(r'^.+?-', f'{int(target_execution_param) - 1}-', request.node.callspec.id)}]"
            ])
        else:
            depends(request, [f"{request.cls.__name__}::test_execution_records_exists[{request.node.callspec.id.rsplit('-', 1)[0]}]"])

        if target_execution['status'] != 'aborted':
            pytest.skip('Execution approval action is not set to `aborted`')

        try:
            execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]
        except IndexError:
            log.info('Executino record status was set to aborted before associated Step Function execution was created')
        else:
            assert sf.describe_execution(executionArn=execution_arn)['status'] == 'ABORTED'

    @pytest.mark.dependency()
    @pytest.mark.usefixtures('action')
    def test_sf_execution_exists(self, request, mut_output, sf, target_execution):
        """Assert execution record has an associated Step Function execution"""

        depends(request, [f"{request.cls.__name__}::test_execution_records_exists[{request.node.callspec.id.rsplit('-', 1)[0]}]"])

        if target_execution['status'] == 'aborted':
            pytest.skip('Execution approval action is set to `aborted`')

        execution_arn = [execution['executionArn'] for execution in sf.list_executions(stateMachineArn=mut_output['state_machine_arn'])['executions'] if execution['name'] == target_execution['execution_id']][0]

        assert sf.describe_execution(executionArn=execution_arn)['status'] in ['RUNNING', 'SUCCEEDED', 'FAILED', 'TIMED_OUT']

    @pytest.mark.dependency()
    @pytest.mark.usefixtures('action')
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

    @pytest.mark.dependency()
    def test_approval_request(self, request, sf, mut_output, target_execution):
        depends(request, [f'{request.cls.__name__}::test_terra_run_plan_codebuild[{request.node.callspec.id}]'])
    
        events = self.get_execution_history(sf, mut_output['state_machine_arn'], target_execution['execution_id'])

        for event in events:
            if event['type'] == 'TaskSubmitted' and event['taskSubmittedEventDetails']['resource'] == 'invoke.waitForTaskToken':
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
    def test_cw_event_trigger_sf(self, request, cb, mut_output, target_execution):
        depends(request, [f'{request.cls.__name__}::test_sf_execution_status[{request.node.callspec.id}]'])
        status = self.get_build_status(cb, mut_output['codebuild_trigger_sf_name'], filters={'initiator': mut_output['cw_rule_initiator']}, sf_execution_filter={'execution_id': target_execution['execution_id']})[0]

        assert status == 'SUCCEEDED'

    @pytest.mark.dependency()
    def test_rollback_providers_executions_exists(self, request, conn, stage, expected_execution_count, pr, action, target_execution):
        """Assert that all expected scenario directories are within executions table"""
        depends(request, [f'{request.cls.__name__}::test_cw_event_trigger_sf[{request.node.callspec.id}]'])

        if stage != 'deploy':
            pytest.skip('Rollback to base commit PR will not be creating new providers')
        elif action != 'reject':
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
        log.debug(f'Stages execution count mapping: {expected_execution_count}')

        assert expected_execution_count['rollback_providers'] == len(target_execution_ids)