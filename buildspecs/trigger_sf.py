import os
import sys
import logging
import subprocess
# import git
import psycopg2
import re

from buildspecs.postgres_helper import PostgresHelper

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TriggerSF(PostgresHelper):
    def __init__(self):
        super().__init__()
    def execution_finished(self):
        if not os.environ['EVENTBRIDGE_EVENT']:
            log.error('EVENTBRIDGE_EVENT is not set')
        
        event = os.environ['EVENTBRIDGE_EVENT']
        self.cur.execute(
            open('./sql/cw_event_status_update.sql', 'r').read(),
            {
                'execution_id': event['execution_id'], 
                'status': event['status']
            }
        )

        if not event['is_rollback']:
            if len(event['new_providers']) > 0:
                log.info('Adding new provider resources to associated execution record')
                update_execution_with_new_resources()

            if event['status'] == 'failed':
                log.info('Updating commit queue and executions to reflect failed execution')
                self.cur.execute(
                    open('./sql/failed_execution_update.sql', 'r').read(),
                    {
                        'commit_id': event['commit_id'],
                        'base_commit_id': base_commit_id,
                        'pr_id': event['pr_id']
                    }
                )
            elif event['is_rollback'] == true and event['status'] == 'failed':
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

    def create_executions():
        commit_item = self.dequeue_commit()

        if commit_item is None:
            log.info('No commits to dequeue -- skipping execution creation')

        commit_id = commit_item['commit_id']
        is_rollback = commit_item['is_rollback']
        is_base_rollback = commit_item['is_base_rollback']

        if is_rollback == true and is_base_rollback == false:
            log.info('Adding commit rollbacks to executions')
            self.cur('./sql/update_executions_with_new_rollback_stack.sql', (commit_id))
        elif (is_rollback == true and is_base_rollback == true) or is_rollback == false:
            log.info('Adding commit deployments to executions')
            update_executions_with_new_deploy_stack()
        else:
            log.error('Could not identitfy commit type')
            log.error('is_rollback: {is_rollback} -- is_base_rollback: {is_base_rollback}')
            
    def start_sf_execution(self):
        log.info('Getting executions that have all account dependencies and terragrunt dependencies met')

        target_execution_ids = self.cur.execute(open('./sql/select_target_execution_ids.sql').read())

        log.info(f'Count: {len(target_execution_ids)}')

        if os.environ['DRY_RUN']:
            log.info('DRY_RUN was set -- skip starting sf executions')
        else:
            for record in target_executions:
                execution_id = record['execution_id']
                log.info(f'Execution ID: {execution_id}')
                
                log.debug('Starting sf execution')
                sf.start_execution()

                log.debug('Updating execution status to running')
                self.cur.execute(f"""
                    UPDATE executions
                    SET status = 'running'
                    WHERE execution_id = '{execution_id}'
                """)

    def execute(self):   
        if 'CODEBUILD_INITIATOR' not in os.environ:
            sys.exit('CODEBUILD_INITIATOR is not set')
        elif 'EVENTBRIDGE_FINISHED_RULE' not in os.environ:
            sys.exit('EVENTBRIDGE_FINISHED_RULE is not set')
        
        log.info('Checking if build was triggered via a finished Step Function execution')
        if os.environ['CODEBUILD_INITIATOR'] == os.environ['EVENTBRIDGE_FINISHED_RULE']:
            log.info('Triggered via Step Function Event')
            self.execution_finished
        
        log.info('Checking if any Step Function executions are running')
        self.cur.execute("SELECT COUNT(*) FROM executions WHERE status = 'running'")
        if self.cur.rowcount == 0:
            log.info('No deployment or rollback executions in progress')
            self.create_executions
        
        log.info('Starting Step Function Deployment Flow')
        self.start_sf_executions()

if __name__ == '__main__':
    trigger = TriggerSF()
    trigger.execute()