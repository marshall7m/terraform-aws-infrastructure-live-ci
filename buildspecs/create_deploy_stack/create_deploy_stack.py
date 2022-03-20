import os
import sys
import logging
import subprocess
import git
import psycopg2
from psycopg2 import sql
from psycopg2.extras import execute_values
import re
import boto3
from pprint import pformat
import sys
import contextlib

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)

class CreateStack:
    def __init__(self):
        self.conn = psycopg2.connect()
        self.conn.set_session(autocommit=True)

        self.cur = self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        self.git_repo = git.Repo(search_parent_directories=True)

    def get_new_providers(self, path):
        log.debug(f'Path: {path}')
        cmd = f"terragrunt providers --terragrunt-working-dir {path}"
        run = subprocess.run(cmd.split(' '), capture_output=True, text=True)

        log.debug(f'Terragrunt providers cmd out:\n{run.stdout}')

        if run.returncode != 0:
            log.error(f'Running cmd: {cmd} resulted in error')
            log.error(f'Cmd stderr:\n{run.stderr}')
            sys.exit(1)
        
        cfg_providers = re.findall(r'(?<=─\sprovider\[).+(?=\])', run.stdout, re.MULTILINE)
        state_providers = re.findall(r'(?<=\s\sprovider\[).+(?=\])', run.stdout, re.MULTILINE)
    
        log.debug(f'Config providers:\n{cfg_providers}')
        log.debug(f'State providers:\n{state_providers}')

        return list(set(cfg_providers).difference(state_providers))

    @contextlib.contextmanager
    def set_aws_env_vars(self, role_arn, session_name):
        sts = boto3.client('sts')
        creds =sts.assume_role(RoleArn=role_arn, RoleSessionName=session_name)['Credentials']

        os.environ['AWS_ACCESS_KEY_ID'] = creds['AccessKeyId']
        os.environ['AWS_SECRET_ACCESS_KEY'] = creds['SecretAccessKey']
        os.environ['AWS_SESSION_TOKEN'] = creds['SessionToken']

        yield None

        del os.environ['AWS_ACCESS_KEY_ID']
        del os.environ['AWS_SECRET_ACCESS_KEY']
        del os.environ['AWS_SESSION_TOKEN']
        
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
            cur.execute('SELECT account_path, plan_role_arn FROM account_dim')
            accounts = [{'path': r[0], 'role': r[1]} for r in cur.fetchall()]

        log.debug(f'Accounts:\n{accounts}')

        if len(accounts) == 0:
            log.fatal('No account paths are defined in account_dim')
            sys.exit(1)

        git_root = self.git_repo.git.rev_parse('--show-toplevel')
        log.debug(f'Git root: {git_root}')
        pr_id = os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[1]

        log.info('Getting account stacks')
        for account in accounts:
            log.info(f'Account path: {account["path"]}')
            log.debug(f'Account plan role ARN: {account["role"]}')

            if not os.path.isdir(account['path']):
                log.error('Account path does not exist within repo')
                sys.exit(1)
            
            with self.set_aws_env_vars(account['role'], 'trigger-sf-terragrunt-plan-all'):
                stack = self.create_stack(account['path'], git_root)

            log.debug(f'Stack:\n{stack}')

            if len(stack) == 0:
                log.debug('Stack is empty -- skipping')
                continue
            
            stack_cols = set().union(*(s.keys() for s in stack))
            
            query = sql.SQL(open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_deploy_stack.sql', 'r').read()).format(
                pr_id=sql.Literal(pr_id),
                commit_id=sql.Literal(os.environ['CODEBUILD_RESOLVED_SOURCE_VERSION']),
                account_path=sql.Literal(account['path']),
                cols=sql.SQL(', ').join(map(sql.Identifier, stack_cols)),
                base_ref=sql.Literal(os.environ['CODEBUILD_WEBHOOK_BASE_REF']),
                head_ref=sql.Literal(os.environ['CODEBUILD_WEBHOOK_HEAD_REF'])
            )
            log.debug(f'Query:\n{query.as_string(self.conn)}')

            col_tpl = '(' + ', '.join([f'%({col})s' for col in stack_cols]) + ')'
            log.debug(f'Stack column template: {col_tpl}')

            res = execute_values(self.cur, query, stack, template=col_tpl, fetch=True)
            log.debug(f'Inserted executions:\n{pformat([dict(r) for r in res])}')

    def main(self):   
        

        if os.environ['CODEBUILD_INITIATOR'].split('/')[0] == 'GitHub-Hookshot' and os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[0] == 'pr':
            ssm = boto3.client('ssm')
            lb = boto3.client('lambda')
            log.info('Locking merge action within target branch')
            ssm.put_parameter(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value=os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[1], Type='String', Overwrite=True)

            log.info('Creating deployment execution records')
            self.update_executions_with_new_deploy_stack()

            log.info(f'Invoking Lambda Function: {os.environ["TRIGGER_SF_FUNCTION_NAME"]}')
            lb.invoke(FunctionName=os.environ['TRIGGER_SF_FUNCTION_NAME'], InvocationType='Event')
        
        else:
            log.error('Codebuild triggered action not handled')
            log.debug(f'CODEBUILD_INITIATOR: {os.environ["CODEBUILD_INITIATOR"]}')
            log.debug(f'CODEBUILD_WEBHOOK_TRIGGER: {os.environ["CODEBUILD_WEBHOOK_TRIGGER"]}')
            sys.exit(1)

    def cleanup(self):

        log.debug('Closing metadb cursor')
        self.cur.close()

        log.debug('Closing metadb connection')
        self.conn.close()

if __name__ == '__main__':
    run = CreateStack()
    run.main()