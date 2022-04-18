import os
import sys
import logging
import subprocess
import git
import aurora_data_api
import re
import boto3
from pprint import pformat
import sys
import contextlib
import json
from typing import List

log = logging.getLogger(__name__)
stream = logging.StreamHandler(sys.stdout)
log.addHandler(stream)
log.setLevel(logging.DEBUG)
ssm = boto3.client('ssm')
lb = boto3.client('lambda')

class CreateStack:
    def __init__(self):
        self.git_repo = git.Repo(search_parent_directories=True)

    def get_new_providers(self, path: str) -> List[str]:
        '''
        Returns list of Terraform provider sources that are defined within the `path` that are not within the terraform state
        
        Arguments:
            path: Absolute path to a directory that contains atleast one Terragrunt *.hcl file
        '''
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
    def set_aws_env_vars(self, role_arn: str, session_name: str) -> None:
        '''
        Sets environment variables for AWS credentials associated with AWS IAM role ARN
        
        Arguments:
            role_arn: AWS IAM role ARN
            session_name: Name of the session to be used while the role is assumed
        '''
        sts = boto3.client('sts')
        creds = sts.assume_role(RoleArn=role_arn, RoleSessionName=session_name)['Credentials']

        os.environ['AWS_ACCESS_KEY_ID'] = creds['AccessKeyId']
        os.environ['AWS_SECRET_ACCESS_KEY'] = creds['SecretAccessKey']
        os.environ['AWS_SESSION_TOKEN'] = creds['SessionToken']

        yield None

        del os.environ['AWS_ACCESS_KEY_ID']
        del os.environ['AWS_SECRET_ACCESS_KEY']
        del os.environ['AWS_SESSION_TOKEN']
        
    def create_stack(self, path: str, git_root: str) -> List[map]:
        '''
        Creates a list of Terragrunt paths that contain differences in their plan with their associated Terragrunt dependencies and new providers

        Arguments:
            path: Directory to run terragrunt run-all plan within. Directory must contain a `terragrunt.hcl` file.
            git_root: The associated Github repository's root absolute directory
        '''
        cmd = f"terragrunt run-all plan --terragrunt-working-dir {path} --terragrunt-non-interactive -detailed-exitcode"
        log.debug(f'Running command: {cmd}')

        run = subprocess.run(cmd.split(' '), capture_output=True, text=True)
        return_code = run.returncode

        if return_code not in [0, 2]:
            log.debug(f'Return code: {return_code}')
            log.debug(run.stderr)
            raise TerragruntException('Terragrunt run-all plan command failed -- Aborting CodeBuild run')  
        
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

    def update_executions_with_new_deploy_stack(self) -> None:
        '''
        Iterates through every parent account-level directory and insert it's associated deployment stack within the metadb
        '''

        with aurora_data_api.connect(
            aurora_cluster_arn=os.environ['METADB_CLUSTER_ARN'],
            secret_arn=os.environ['METADB_SECRET_ARN'],
            database=os.environ['METADB_NAME']
        ) as conn:
            with conn.cursor() as cur:
                cur.execute('SELECT account_path, plan_role_arn FROM account_dim')
                accounts = [{'path': r[0], 'role': r[1]} for r in cur.fetchall()]

                log.debug(f'Accounts:\n{accounts}')

                if len(accounts) == 0:
                    log.fatal('No account paths are defined in account_dim')
                    sys.exit(1)

                git_root = self.git_repo.git.rev_parse('--show-toplevel')
                log.debug(f'Git root: {git_root}')
                pr_id = os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[1]
                try:
                    log.info('Getting account stacks')
                    for account in accounts:
                        log.info(f'Account path: {account["path"]}')
                        log.debug(f'Account plan role ARN: {account["role"]}')

                        if not os.path.isdir(account['path']):
                            raise ClientException(f'Account path does not exist within repo: {account["path"]}')
                        
                        with self.set_aws_env_vars(account['role'], 'trigger-sf-terragrunt-plan-all'):
                            stack = self.create_stack(account['path'], git_root)

                        log.debug(f'Stack:\n{stack}')

                        if len(stack) == 0:
                            log.debug('Stack is empty -- skipping')
                            continue
        
                        with open(f'{os.path.dirname(os.path.realpath(__file__))}/sql/update_executions_with_new_deploy_stack.sql', 'r') as f:
                            query = f.read().format(
                                pr_id=pr_id,
                                commit_id=os.environ['CODEBUILD_RESOLVED_SOURCE_VERSION'],
                                account_path=account['path'],
                                base_ref=os.environ['CODEBUILD_WEBHOOK_BASE_REF'],
                                head_ref=os.environ['CODEBUILD_WEBHOOK_HEAD_REF']
                            )
                        log.debug(f'Query:\n{query}')
                        
                        #convert lists to comma-delimitted strings that will parsed to TEXT[] within query
                        for cfg in stack:
                            for k, v in cfg.items():
                                if type(v) == list:
                                    cfg.update({k: ','.join(v)})

                        cur.executemany(query, stack)
                except Exception as e:
                    log.info('Rolling back execution insertions')
                    cur.rollback()
                    raise e
            return None

    def main(self) -> None:
        '''
        When a PR that contains Terragrunt and/or Terraform changes is merged within the base branch, each of those new/modified Terragrunt directories will have an associated
        deployment record inserted into the metadb. After all records are inserted, a downstream AWS Lambda function will choose which of those records to run through the deployment flow.
        '''
        if os.environ['CODEBUILD_INITIATOR'].split('/')[0] == 'GitHub-Hookshot' and os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[0] == 'pr':
            log.info('Locking merge action within target branch')
            ssm.put_parameter(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value=os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[1], Type='String', Overwrite=True)

            try:
                log.info('Creating deployment execution records')
                self.update_executions_with_new_deploy_stack()
            except Exception as e:
                log.error(e, exc_info=True)
                log.info('Unlocking merge action within target branch')
                ssm.put_parameter(Name=os.environ['GITHUB_MERGE_LOCK_SSM_KEY'], Value='none', Type='String', Overwrite=True)
                raise e

            log.info(f'Invoking Lambda Function: {os.environ["TRIGGER_SF_FUNCTION_NAME"]}')
            lb.invoke(FunctionName=os.environ['TRIGGER_SF_FUNCTION_NAME'], InvocationType='Event', Payload=json.dumps({'pr_id': os.environ['CODEBUILD_WEBHOOK_TRIGGER'].split('/')[1]}))
        
        else:
            log.error('Codebuild triggered action not handled')
            log.debug(f'CODEBUILD_INITIATOR: {os.environ["CODEBUILD_INITIATOR"]}')
            log.debug(f'CODEBUILD_WEBHOOK_TRIGGER: {os.environ["CODEBUILD_WEBHOOK_TRIGGER"]}')
            sys.exit(1)

        return None
    def cleanup(self):

        log.debug('Closing metadb cursor')
        self.cur.close()

        log.debug('Closing metadb connection')
        self.conn.close()

if __name__ == '__main__':
    run = CreateStack()
    run.main()

class TerragruntException(Exception):
    pass

class ClientException(Exception):
    pass