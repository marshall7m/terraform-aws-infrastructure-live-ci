import os
import sys
import logging
import subprocess
import git
import psycopg2
from psycopg2 import sql
from psycopg2.extras import execute_values
import pandas.io.sql as psql
import re
import json
import boto3
import pandas as pd


log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
sf = boto3.client('stepfunctions', region_name='us-west-2')

class TriggerSF:
    def __init__(self):
        self.conn = psycopg2.connect()
        self.conn.set_session(autocommit=True)

        self.cur = self.conn.cursor()
        self.git_repo = git.Repo(search_parent_directories=True)

    def create_sql_utils(self):
        log.debug('Creating postgres utility functions')
        files = [f'{os.path.dirname(os.path.realpath(__file__))}/sql/utils.sql']

        for file in files:
            log.debug(f'File: {file}')
            with open(file, 'r') as f:
                content = f.read()
                log.debug(f'Content: {content}')
                self.cur.execute(content)
    
    def get_new_provider_resources(self, tg_dir, commit_id, new_providers):
        self.git_repo.git.checkout(commit_id)

        out = json.load(subprocess.run(f'terragrunt state pull --terragrunt-working-dir {tg_dir}'.split(' ')))
        
        return [resource['type'] + '.' + resource['name'] for resource in out['resources'] if resource['provider'] in new_providers]

    def execution_finished(self):

        event = json.loads(os.environ['EVENTBRIDGE_EVENT'])
        with pd.option_context('display.max_rows', None, 'display.max_columns', None):
            log.debug(f'Parsed CW event:\n{pd.DataFrame.from_records([event]).T}')
        
        with open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/cw_event_status_update.sql', 'r') as f:
            self.cur.execute(sql.SQL(f.read()).format(
                execution_id=sql.Literal(event['execution_id']),
                status=sql.Literal(event['status'])
            ))

            log.debug(f'Notices:\n{self.conn.notices}')
        
        if not event['is_rollback']:
            if len(event['new_providers']) > 0:
                log.info('Adding new provider resources to associated execution record')
                resources = self.get_new_provider_resources(event['cfg_path'], event['commit_id'], event['new_providers'])
                self.cur.execute(sql.SQL(
                    "UPDATE EXECUTION SET new_resources = % WHERE execution_id = %"
                ), (resources, event['execution_id']))

            if event['status'] == 'failed':
                log.info('Updating commit queue and executions to reflect failed execution')
                base_commit_id = git.repo.fun.rev_parse(self.git_repo, os.environ['BASE_REF'])

                self.cur.execute(
                    sql.SQL(open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/failed_execution_update.sql', 'r').read()).format(
                        commit_id=sql.Literal(event['commit_id']),
                        base_commit_id=sql.Literal(base_commit_id),
                        pr_id=sql.Literal(event['pr_id'])
                    )
                )
            elif event['is_rollback'] == True and event['status'] == 'failed':
                log.error("Rollback execution failed -- User with administrative privileges will need to manually fix configuration")
                exit(1)
        
    def dequeue_commit(self):
        commit_item = self.cur.execute(open('dequeue_rollback_commit.sql', 'r').read())

        if commit_item:
            return commit_item
        
        log.info('Dequeuing next PR if commit queue is empty')
        pr_items = self.cur.execute(open('dequeue_pr.sql', 'r').read())

        if pr_items:
            log.info("Updating commit queue with dequeued PR's most recent commit")

            log.debug('Dequeued pr items:')
            log.debug(pr_items)

            pr_id = pr_items['pr_id']
            head_ref = pr_items['head_ref']
            log.debug('Fetching PR from remote')
            cmd = f'git fetch origin pull/{pr_id}/head:{head_ref} && git checkout {head_ref}'
            subprocess.run(cmd, capture_output=False)
            
            head_commit_id = subprocess.run("git log --pretty=format:'%H' -n ".split(' '), capture_output=True, text=True).stdout
            
            commit_item = self.cur.execute(f"""
            INSERT INTO commit_queue (
                commit_id,
                is_rollback,
                is_base_rollback,
                pr_id,
                status
            )
            VALUES (
                '{head_commit_id}',
                false,
                false,
                '{pr_id}',
                'running'
            )
            RETURNING row_to_json(commit_queue.*);
            """)
            
            log.info('Switching back to default branch')
            subprocess.run('git switch -', capture_output=False)
        else:
            log.info('Another PR is in progress or no PR is waiting')
        
        return commit_item
    
    def update_executions_with_new_deploy_stack(self, commit_id):
        self.cur('SELECT account_path FROM account_dim')

        account_paths = self.cur.fetch_all()

        if len(account_paths) == 0:
            log.error('No account paths are defined in account_dim')
        
        log.info(f'Checking out target commit ID: {commit_id}')
        self.git_repo.checkout(commit_id)
        git_root = self.git_repo()
        log.debug(f'Git root: {git_root}')

        base_commit_id = git.repo.fun.rev_parse(self.git_repo, os.environ['BASE_REF'])

        log.info('Getting account stacks')
        for path in account_paths:
            log.info(f'Account path: {path}')
            self.cur('DROP TABLE IF EXISTS staging_cfg_stack')

            if not os.path.isdir(path):
                log.error('Account path does not exist within repo')
            
            stack = self.create_stack(path, git_root)

            log.debug(f'Stack:\n{stack}')

            if stack == None:
                log.debug('Stack is empty -- skipping')
                continue
            
            query = sql.SQL(open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_deploy_stack.sql', 'r').read()).format(
                base_commit_id=base_commit_id,
                commit_id=sql.Literal(commit_id),
                account_path=path
            )

            log.debug(f'Query:\n{query.as_string(self.conn)}')
            values = [[value for value in s.values()] for s in stack]

            res = execute_values(self.cur, query, values, fetch=True)
            log.debug(f'Inserted executions:\n{res}')

    def create_executions(self):
        commit_item = self.dequeue_commit()

        if commit_item is None:
            log.info('No commits to dequeue -- skipping execution creation')

        commit_id = commit_item['commit_id']
        is_rollback = commit_item['is_rollback']
        is_base_rollback = commit_item['is_base_rollback']

        if is_rollback == True and is_base_rollback == False:
            log.info('Adding commit rollbacks to executions')
            self.cur('./sql/update_executions_with_new_rollback_stack.sql', (commit_id))
        elif (is_rollback == True and is_base_rollback == True) or is_rollback == False:
            log.info('Adding commit deployments to executions')
            self.update_executions_with_new_deploy_stack(commit_id)
        else:
            log.error('Could not identitfy commit type')
            log.error('is_rollback: {is_rollback} -- is_base_rollback: {is_base_rollback}')
            
    def start_sf_executions(self):
        log.info('Getting executions that have all account dependencies and terragrunt dependencies met')

        self.cur.execute(open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/select_target_execution_ids.sql').read())

        target_execution_ids = [id[0] for id in self.cur.fetchall() if id[0] != None]
        log.debug(f'IDs: {target_execution_ids}')
        log.info(f'Count: {len(target_execution_ids)}')

        if 'DRY_RUN' in os.environ:
            log.info('DRY_RUN was set -- skip starting sf executions')
        elif len(target_execution_ids) == 0:
            log.info('No executions are ready')
        else:
            with self.conn.cursor(cursor_factory = psycopg2.extras.RealDictCursor) as cur:
                for id in target_execution_ids:
                    log.info(f'Execution ID: {id}')

                    cur.execute(sql.SQL("""
                        SELECT *
                        FROM queued_executions 
                        WHERE execution_id = %s
                        ) sub
                    """).format(sql.Literal(id)))

                    sf_input = cur.fetchone()
                    
                    log.debug(f'SF input:\n{sf_input}')
                    log.debug('Starting sf execution')
                    
                    sf.start_execution(stateMachineArn=os.environ['STATE_MACHINE_ARN'], name=id, input=json.dumps(sf_input))

                    log.debug('Updating execution status to running')
                    cur.execute(sql.SQL("""
                        UPDATE executions
                        SET status = 'running'
                        WHERE execution_id = %s
                    """).format(sql.Literal(id)))
            
    def main(self):   
        self.create_sql_utils()

        if 'CODEBUILD_INITIATOR' not in os.environ:
            sys.exit('CODEBUILD_INITIATOR is not set')
        elif 'EVENTBRIDGE_FINISHED_RULE' not in os.environ:
            sys.exit('EVENTBRIDGE_FINISHED_RULE is not set')
        
        log.info('Checking if build was triggered via a finished Step Function execution')
        if os.environ['CODEBUILD_INITIATOR'] == os.environ['EVENTBRIDGE_FINISHED_RULE']:
            log.info('Triggered via Step Function Event')
            self.execution_finished()
        
        log.info('Checking if any Step Function executions are running')
        self.cur.execute("SELECT COUNT(*) FROM executions WHERE status = 'running'")
        if self.cur.rowcount == 0:
            log.info('No deployment or rollback executions in progress')
            self.create_executions()
        
        log.info('Starting Step Function Deployment Flow')
        self.start_sf_executions()

    def cleanup(self):

        log.debug('Closing metadb cursor')
        self.cur.close()

        log.debug('Closing metadb connection')
        self.conn.close()

if __name__ == '__main__':
    trigger = TriggerSF()
    trigger.main()