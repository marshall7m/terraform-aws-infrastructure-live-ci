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
import sys

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)
sf = boto3.client('stepfunctions', region_name='us-west-2')

class TriggerSF:
    def __init__(self):
        self.conn = psycopg2.connect()
        self.conn.set_session(autocommit=True)

        self.cur = self.conn.cursor(cursor_factory = psycopg2.extras.RealDictCursor)
        self.git_repo = git.Repo(search_parent_directories=True)

    def create_sql_utils(self):
        log.debug('Creating postgres utility functions')
        files = [f'{os.path.dirname(os.path.realpath(__file__))}/sql/utils.sql']

        for file in files:
            log.debug(f'File: {file}')
            with open(file, 'r') as f:
                self.cur.execute(f.read())
    
    def get_new_provider_resources(self, tg_dir, commit_id, new_providers):
        self.git_repo.git.checkout(commit_id)

        out = json.load(subprocess.run(f'terragrunt state pull --terragrunt-working-dir {tg_dir}'.split(' ')))
        
        return [resource['type'] + '.' + resource['name'] for resource in out['resources'] if resource['provider'] in new_providers]

    def execution_finished(self, event):
        
        self.cur.execute(sql.SQL("""
        UPDATE executions
        SET "status" = {}
        WHERE execution_id = {}
        """).format(
            sql.Literal(event['status']),
            sql.Literal(event['execution_id'])
        ))
        
        if not event['is_rollback']:
            if len(event['new_providers']) > 0:
                log.info('Adding new provider resources to associated execution record')
                resources = self.get_new_provider_resources(event['cfg_path'], event['commit_id'], event['new_providers'])
                self.cur.execute(sql.SQL(
                    "UPDATE EXECUTION SET new_resources = % WHERE execution_id = %"
                ), (resources, event['execution_id']))

            if event['status'] == 'failed':
                log.info('Aborting deployments depending on failed execution')

                self.cur.execute(
                    sql.SQL("""
                    UPDATE executions
                    SET "status" = 'aborted'
                    WHERE "status" = 'waiting'
                    AND commit_id = {}
                    AND is_rollback = false;
                    """).format(
                        commit_id=sql.Literal(event['commit_id'])
                    )
                )
            elif event['is_rollback'] == True and event['status'] == 'failed':
                log.error("Rollback execution failed -- User with administrative privileges will need to manually fix configuration")
                sys.exit(1)

    def get_new_providers(self, path):
        log.debug(f'Path: {path}')

        out = subprocess.run(f"terragrunt providers --terragrunt-working-dir {path}".split(' '), capture_output=True, text=True).stdout
        cfg_providers = re.findall(r'(?<=─\sprovider\[).+(?=\])', out, re.MULTILINE)
        state_providers = re.findall(r'(?<=\s\sprovider\[).+(?=\])', out, re.MULTILINE)
        
        log.debug(f'Config providers:\n{cfg_providers}')
        log.debug(f'State providers:\n{state_providers}')

        return list(set(cfg_providers).difference(state_providers))

    def create_stack(self, path, git_root):
        cmd = f"terragrunt run-all plan --terragrunt-working-dir {path} --terragrunt-non-interactive -detailed-exitcode"

        run = subprocess.run(cmd.split(' '), capture_output=True, text=True)
        out = run.stderr
        return_code = run.returncode

        if return_code not in [0, 2]:
            log.fatal('Terragrunt run-all plan command failed -- Aborting CodeBuild run')  
            log.debug(f'Return code: {return_code}')
            log.debug(out)
            sys.exit(1)
        
        diff_paths = re.findall(r'(?<=exit\sstatus\s2\n\n\sprefix=\[).+?(?=\])', out, re.DOTALL)
        if len(diff_paths) == 0:
            log.debug('Detected no Terragrunt paths with difference')
            # log.debug(out)
            return []
        else:
            log.debug(f'Detected new/modified Terragrunt paths:\n{diff_paths}')
        
        stack = []
        for m in re.finditer(r'=>\sModule\s(?P<cfg_path>.+?)\s\(excluded:.+dependencies:\s\[(?P<cfg_deps>.+|)\]', out, re.MULTILINE):
            if m.group(1) in diff_paths:
                cfg = m.groupdict()

                cfg['cfg_path'] = os.path.relpath(cfg['cfg_path'], git_root)
                cfg['cfg_deps'] = [os.path.relpath(path, git_root) for path in cfg['cfg_deps'].replace(',', '').split() if path in diff_paths]
                cfg['new_providers'] = self.get_new_providers(cfg['cfg_path'])

                stack.append(cfg)

        return stack

    def update_executions_with_new_deploy_stack(self):
        with self.conn.cursor() as cur:
            cur.execute('SELECT account_path FROM account_dim')
            account_paths = [path for t in cur.fetchall() for path in t]

        log.debug(f'Account Paths:\n{account_paths}')

        if len(account_paths) == 0:
            log.fatal('No account paths are defined in account_dim')
            sys.exit(1)

        git_root = self.git_repo.git.rev_parse('--show-toplevel')
        log.debug(f'Git root: {git_root}')
        pr_id = os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[1]

        log.info('Getting account stacks')
        for path in account_paths:
            log.info(f'Account path: {path}')

            if not os.path.isdir(path):
                log.error('Account path does not exist within repo')
                sys.exit(1)
            
            stack = self.create_stack(path, git_root)

            log.debug(f'Stack:\n{stack}')

            if len(stack) == 0:
                log.debug('Stack is empty -- skipping')
                continue
            
            stack_cols = set().union(*(s.keys() for s in stack))
            
            query = sql.SQL(open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_deploy_stack.sql', 'r').read()).format(
                pr_id=sql.Literal(pr_id),
                commit_id=sql.Literal(os.environ['CODEBUILD_SOURCE_VERSION']),
                account_path=sql.Literal(path),
                cols=sql.SQL(', ').join(map(sql.Identifier, stack_cols)),
                base_ref=sql.Literal(os.environ['CODEBUILD_WEBHOOK_BASE_REF']),
                head_ref=sql.Literal(os.environ['CODEBUILD_WEBHOOK_HEAD_REF'])
            )
            log.debug(f'Query:\n{query.as_string(self.conn)}')

            col_tpl = '(' + ', '.join([f'%({col})s' for col in stack_cols]) + ')'
            log.debug(f'Stack column template: {col_tpl}')

            res = execute_values(self.cur, query, stack, template=col_tpl, fetch=True)
            
            with pd.option_context('display.max_rows', None, 'display.max_columns', None):
                log.debug(f'Inserted executions:\n{pd.DataFrame([dict(r) for r in res]).T}')
            
    def start_sf_executions(self):
        log.info('Getting executions that have all account dependencies and terragrunt dependencies met')

        with self.conn.cursor() as cur:
            with open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/select_target_execution_ids.sql') as f:
                cur.execute(f.read())
                ids = cur.fetchone()[0]
            if ids == None:
                log.info('No executions are ready')
                return
            else:
                target_execution_ids = [id for id in ids]

        log.debug(f'IDs: {target_execution_ids}')
        log.info(f'Count: {len(target_execution_ids)}')

        if 'DRY_RUN' in os.environ:
            log.info('DRY_RUN was set -- skip starting sf executions')
        else:
            for id in target_execution_ids:
                log.info(f'Execution ID: {id}')

                self.cur.execute(sql.SQL("""
                    SELECT *
                    FROM queued_executions 
                    WHERE execution_id = {}
                """).format(sql.Literal(id)))

                sf_input = json.dumps(self.cur.fetchone())
                log.debug(f'SF input:\n{sf_input}')

                log.debug('Starting sf execution')
                sf.start_execution(stateMachineArn=os.environ['STATE_MACHINE_ARN'], name=id, input=sf_input)

                log.debug('Updating execution status to running')
                self.cur.execute(sql.SQL("""
                    UPDATE executions
                    SET status = 'running'
                    WHERE execution_id = {}
                """).format(sql.Literal(id)))
            
    def main(self):   
        self.create_sql_utils()
        
        if os.environ['CODEBUILD_INITIATOR'] == os.getenv('EVENTBRIDGE_FINISHED_RULE'):
            log.info('Triggered via Step Function Event')

            event = json.loads(os.environ['EVENTBRIDGE_EVENT'])
            with pd.option_context('display.max_rows', None, 'display.max_columns', None):
                log.debug(f'Parsed CW event:\n{pd.DataFrame.from_records([event]).T}')
    
            self.execution_finished(event)

            log.info('Checking if any Step Function executions are running')
            self.cur.execute("SELECT * FROM executions WHERE status = 'running'")
            running_execution_count = self.cur.rowcount
            
            if running_execution_count == 0:
                log.info('No deployment or rollback executions in progress')
                if event['status'] == 'failed' and event['is_rollback'] == False:
                    log.info('Adding commit rollbacks to executions')
                    with open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_rollback_stack.sql', 'r') as f:
                        self.cur.execute(sql.SQL(f.read()).format(commit_id=sql.Literal(event['commit_id'])))

                    log.debug(f'Rollback Providers execution records:\n{pd.Dataframe([dict(r) for r in self.cur.fetchall()]).T}')
            else:
                log.info(f'Running executions: {running_execution_count} -- skipping execution creation')

        elif os.environ['CODEBUILD_INITIATOR'].split('/')[0] == 'GitHub-Hookshot' and os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[0] == 'pr':
            log.info('Locking merge actions within target branch')
            #TODO: Set commit status to pending for all PR commits
            self.update_executions_with_new_deploy_stack()
        
        else:
            log.error('Codebuild triggered action not handled')
            sys.exit(1)
    
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