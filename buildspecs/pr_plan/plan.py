import os
import json
import logging
import git
import subprocess

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

class TerragruntException(Exception):
    '''Wraps around Terragrunt-related errors'''
    pass


def main() -> None:
    '''Runs Terragrunt plan command on every Terragrunt directory that has been modified'''
    fail_build = False
    for account in json.loads(os.environ['ACCOUNT_DIM']):
        log.debug(f'Account Record:\n{account}')

        repo = git.Repo(search_parent_directories=True)
        diff_paths = []
        for diff in repo.heads.master.commit.diff(os.environ['CODEBUILD_RESOLVED_SOURCE_VERSION'], paths=[f'{account["path"]}/**.hcl', f'{account["path"]}/**.tf']):
            if diff.change_type in ['A', 'M']:
                diff_paths.append(os.path.dirname(diff.a_path))
        diff_paths = list(set(diff_paths))

        if len(diff_paths) > 0:
            log.info(f'New/Modified Directories:\n{diff_paths}')
            log.info(f'Count: {len(diff_paths)}')

            log.info('Running Terragrunt plans')
            log.info(f'Plan Role ARN: {account["plan_role_arn"]}')
            for path in diff_paths:
                log.info(f'Directory: {path}')
                cmd = f'terragrunt plan --terragrunt-working-dir {path} --terragrunt-iam-role {account["plan_role_arn"]}'
                log.debug(f'Command: {cmd}')
                try:
                    run = subprocess.run(cmd.split(' '), capture_output=True, text=True, check=True)
                    print(run.stdout)
                except subprocess.CalledProcessError as e:
                    log.debug('Command failed -- build will fail')
                    #if terragrunt plan fails, skips raising an error until all terragrunt plans have been displayed
                    fail_build = True
                    print(e.stderr)
                    print(e)
        else:
            log.info('No New/Modified Terraform configurations within account -- skipping Terraform plan')

    if fail_build:
        raise TerragruntException('One or more plan failed -- failing build')

if __name__ == '__main__':
    main()