import os
import sys
import logging
import subprocess
import git
from github import Github
import psycopg2
from psycopg2 import sql
from psycopg2.extras import execute_values
import re
import json
import boto3
from pprint import pprint
import sys

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TriggerSF:
    def __init__(self):
        # define boto3 clients within class to allow pytest runtime env vars to fill in client params
        rds = boto3.client('rds')

        token = rds.generate_db_auth_token(
            DBHostname=os.environ["PGHOST"],
            Port=os.environ["PGPORT"], 
            DBUsername=os.environ["PGUSER"]
        )
        self.conn = psycopg2.connect(password=token)
        self.conn.set_session(autocommit=True)

        self.cur = self.conn.cursor(cursor_factory = psycopg2.extras.RealDictCursor)
        self.git_repo = git.Repo(search_parent_directories=True)
    
    def get_new_provider_resources(self, tg_dir, commit_id, new_providers):
        self.git_repo.git.checkout(commit_id)

        cmd = f'terragrunt state pull --terragrunt-working-dir {tg_dir}'
        run = subprocess.run(cmd.split(' '), capture_output=True, text=True, check=True)
        
        if not run.stdout:
            # empty config
            return []
        
        return [resource['type'] + '.' + resource['name'] for resource in json.loads(run.stdout)['resources'] if resource['provider'].split('\"')[1] in new_providers]

    def execution_finished(self, event):
        sf = boto3.client('stepfunctions')

        log.info('Updating execution record status')
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
                self.cur.execute(sql.SQL("""
                UPDATE executions 
                SET new_resources = {} 
                WHERE execution_id = {}
                RETURNING new_resources
                """).format(
                    sql.Literal(resources),
                    sql.Literal(event['execution_id'])
                ))

                log.debug(self.cur.fetchall())

            if event['status'] == 'failed':
                log.info('Aborting all deployments for commit')
                self.cur.execute(
                    sql.SQL("""
                    UPDATE executions
                    SET "status" = 'aborted'
                    WHERE "status" IN ('waiting', 'running')
                    AND commit_id = {}
                    AND is_rollback = false
                    RETURNING execution_id
                    """).format(sql.Literal(event['commit_id']))
                )

                log.info('Aborting Step Function executions')

                aborted_ids = [rec[0] for rec in self.cur.fetchall()]
                log.debug('Execution IDs:\n{aborted_ids}')

                for id in aborted_ids:
                    sf.stop_execution(
                        executionArn=f'{os.environ["STATE_MACHINE_ARN"]}/{id}',
                        error='DependencyError',
                        cause=f'cfg_path dependency failed: {event["cfg_path"]}'
                    )

                log.info('Creating rollback executions if needed')
                with open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_rollback_stack.sql', 'r') as f:
                    self.cur.execute(sql.SQL(f.read()).format(commit_id=sql.Literal(event['commit_id'])))
                    rollback_records = [dict(r) for r in self.cur.fetchall()]
        
                rollback_count = len(rollback_records)
                log.info(f'Rollback count: {rollback_count}')
                if rollback_count > 0:
                    log.debug(f'Rollback records:\n{pprint(rollback_records)}')
    
        elif event['is_rollback'] == True and event['status'] == 'failed':
            log.error("Rollback execution failed -- User with administrative privileges will need to manually fix configuration")
            sys.exit(1)

    def get_new_providers(self, path):
        log.debug(f'Path: {path}')
        cmd = f"terragrunt providers --terragrunt-working-dir {path}"
        run = subprocess.run(cmd.split(' '), capture_output=True, text=True, check=True)

        log.debug(f'Terragrunt providers cmd out:\n{run.stdout}')
        log.debug(f'Terragrunt providers cmd stderr:\n{run.stderr}')
        
        cfg_providers = re.findall(r'(?<=─\sprovider\[).+(?=\])', run.stdout, re.MULTILINE)
        state_providers = re.findall(r'(?<=\s\sprovider\[).+(?=\])', run.stdout, re.MULTILINE)
    
        log.debug(f'Config providers:\n{cfg_providers}')
        log.debug(f'State providers:\n{state_providers}')

        return list(set(cfg_providers).difference(state_providers))

    def create_stack(self, path, git_root):
        cmd = f"terragrunt run-all plan --terragrunt-working-dir {path} --terragrunt-non-interactive -detailed-exitcode"

        run = subprocess.run(cmd.split(' '), capture_output=True, text=True)
        return_code = run.returncode

        if return_code not in [0, 2]:
            log.fatal('Terragrunt run-all plan command failed -- Aborting CodeBuild run')  
            log.debug(f'Return code: {return_code}')
            log.debug(run.stderr)
            sys.exit(1)
        
        diff_paths = re.findall(r'(?<=exit\sstatus\s2\n\n\sprefix=\[).+?(?=\])', run.stderr, re.DOTALL)
        if len(diff_paths) == 0:
            log.debug('Detected no Terragrunt paths with difference')
            return []
        else:
            log.debug(f'Detected new/modified Terragrunt paths:\n{diff_paths}')
        
        stack = []
        for m in re.finditer(r'=>\sModule\s(?P<cfg_path>.+?)\s\(excluded:.+dependencies:\s\[(?P<cfg_deps>.+|)\]', run.stderr, re.MULTILINE):
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
            
            log.debug(f'Inserted executions:\n{pprint([dict(r) for r in res])}')
            
    def start_sf_executions(self):
        sf = boto3.client('stepfunctions')

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
        ssm = boto3.client('ssm')
        
        if os.environ['CODEBUILD_INITIATOR'] == os.getenv('EVENTBRIDGE_FINISHED_RULE'):
            log.info('Triggered via Step Function Event')
            event = json.loads(os.environ['EVENTBRIDGE_EVENT'])
            log.debug(f'Parsed CW event:\n{pprint(event)}')

            self.execution_finished(event)

        elif os.environ['CODEBUILD_INITIATOR'].split('/')[0] == 'GitHub-Hookshot' and os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[0] == 'pr':
            log.info('Locking merge action within target branch')
            ssm.put_parameter(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value=True, Type='String', Overwrite=True)

            log.info('Creating deployment execution records')
            self.update_executions_with_new_deploy_stack()
        
        else:
            log.error('Codebuild triggered action not handled')
            sys.exit(1)

        log.info('Checking if commit executions are in progress')
        self.cur.execute("SELECT * FROM executions WHERE status IN ('waiting', 'running')")

        if self.cur.rowcount > 0:
            log.info('Starting Step Function Deployment Flow')
            self.start_sf_executions()
        else:
            log.info('No executions are waiting or running -- unlocking merge action within target branch')
            ssm.put_parameter(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value=False, Type='String', Overwrite=True)
    def cleanup(self):

        log.debug('Closing metadb cursor')
        self.cur.close()

        log.debug('Closing metadb connection')
        self.conn.close()

if __name__ == '__main__':
    trigger = TriggerSF()
    trigger.main()