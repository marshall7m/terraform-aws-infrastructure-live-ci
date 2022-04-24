import os
import json
import logging
import git
import subprocess
import sys

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)


def main():
    fail_build = False
    for account in json.loads(os.environ['ACCOUNT_DIM']):
        log.debug(f'Account Record:\n{account}')

        repo = git.Repo(search_parent_directories=True)

        head_ref = repo.git.branch('-r', '--contains', os.environ['CODEBUILD_RESOLVED_SOURCE_VERSION'])
        log.debug(f'Remote Head Ref: {head_ref}')
        
        diff_filepaths = repo.diff(head_ref)

        if len(diff_filepaths) > 0:
            diff_paths = []
            for filepath in diff_filepaths:
                diff_paths.append(os.path.dirname(filepath))
            
            diff_paths = list(set(diff_paths))

            log.info(f'New/Modified Directories:\n{diff_paths}')
            log.info(f'Count: {len(diff_paths)}')

            log.info('Running Terragrunt plan on directories')
            log.info(f'Plan Role ARN: {account["plan_role_arn"]}')
            for path in diff_paths:
                log.info(f'Directory: {path}')
                cmd = f'terragrunt plan --terragrunt-working-dir {path} --terragrunt-iam-role {account["plan_role_arn"]}'
                log.debug(f'Command: {cmd}')
                run = subprocess.run(cmd.split(' '), capture_output=True, text=True)

                print(run.stdout)

                if run.returncode != 0:
                    fail_build = True
                    print(run.stderr)
        else:
            log.info('No New/Modified Terraform configurations within account -- skipping Terraform plan')

    if fail_build:
        sys.exit(1)

if __name__ == '__main__':
    main()