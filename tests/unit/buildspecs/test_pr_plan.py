from unittest import mock
import pytest
import os
import logging
import json
import uuid
import subprocess
from unittest.mock import patch
from tests.helpers.utils import dummy_tf_output
from buildspecs.pr_plan import plan
from buildspecs import TerragruntException

log = logging.getLogger(__name__)
log.setLevel(logging.DEBUG)

account_dim = [
    {
        'path': 'directory_dependency/dev-account',
        'plan_role_arn': 'test-plan-role'
    },
    {
        'path': 'directory_dependency/shared-services-account',
        'plan_role_arn': 'test-plan-role'
    }
]
@patch.dict(os.environ, {'ACCOUNT_DIM': json.dumps(account_dim)})
@patch('subprocess.run')
@pytest.mark.parametrize('repo_changes,plan_side_effect,expected_plan_dirs,expected_failure', [
    pytest.param(
        {
            'directory_dependency/dev-account/us-west-2/env-one/doo/a.tf': dummy_tf_output(),
            'directory_dependency/dev-account/us-west-2/env-one/doo/b.tf': dummy_tf_output(),
            'directory_dependency/dev-account/global/a.tf': dummy_tf_output(),
            'directory_dependency/shared-services-account/global/a.txt': '',
        },
        None,
        ['directory_dependency/dev-account/us-west-2/env-one/doo', 'directory_dependency/dev-account/global'],
        False,
        id='successful'
    ),
    pytest.param(
        {
            'directory_dependency/dev-account/us-west-2/env-one/doo/a.tf': dummy_tf_output(),
            'directory_dependency/dev-account/global/a.tf': dummy_tf_output()
        },
        [subprocess.CalledProcessError(cmd='', returncode=1, stderr='error')],
        ['directory_dependency/dev-account/us-west-2/env-one/doo', 'directory_dependency/dev-account/global'],
        True,
        id='tg_error'
    )
], indirect=['repo_changes'])
def test_main(mock_tg_plan, git_repo, repo_changes, plan_side_effect, expected_plan_dirs, expected_failure):
    mock_tg_plan.side_effect = plan_side_effect

    log.debug("Changing to the test repo's root directory")
    git_root = git_repo.git.rev_parse('--show-toplevel')
    os.chdir(git_root)

    test_branch = git_repo.create_head(f'test-{uuid.uuid4()}').checkout().repo
    test_branch.index.add(list(repo_changes.keys()))
    commit = test_branch.index.commit('Add terraform testing changes')
    
    os.environ['CODEBUILD_RESOLVED_SOURCE_VERSION'] = commit.hexsha
    try:
        plan.main()
    except Exception as e:
        if not expected_failure:
            raise e

    log.info('Assert Terragrunt plan command was runned with expected arguments')
    log.debug(mock_tg_plan.call_args_list)
    expected_cmds = [f'terragrunt plan --terragrunt-working-dir {dir} --terragrunt-iam-role {account_dim[0]["plan_role_arn"]}'.split(' ') for dir in expected_plan_dirs]

    actual_cmds = [call[0][0] for call in mock_tg_plan.call_args_list]
    for cmd in expected_cmds:
        assert cmd in actual_cmds

    assert len(actual_cmds) == len(expected_cmds)