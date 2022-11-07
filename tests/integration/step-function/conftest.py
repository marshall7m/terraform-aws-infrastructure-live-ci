import pytest
import os
import logging

log = logging.getLogger(__file__)
log.setLevel(logging.DEBUG)


@pytest.fixture
def base_input(mut_output, push_changes):
    cfg_path = os.path.dirname(list(push_changes["changes"].keys())[0])
    return {
        "execution_id": "run-123",
        "plan_command": f"terragrunt plan --terragrunt-working-dir {cfg_path} --terragrunt-iam-role {mut_output['plan_role_arn']} -auto-approve",
        "apply_command": f"terragrunt apply --terragrunt-working-dir {cfg_path} --terragrunt-iam-role {mut_output['apply_role_arn']} -auto-approve",
        "plan_role_arn": mut_output["ecs_apply_role_arn"],
        "apply_role_arn": mut_output["ecs_apply_role_arn"],
        "cfg_path": cfg_path,
        "cfg_deps": [],
        "status": "running",
        "is_rollback": False,
        "new_providers": [],
        "commit_id": push_changes["commit_id"],
        "account_name": mut_output["account_parent_cfg"][0]["name"],
        "account_path": mut_output["account_parent_cfg"][0]["path"],
        "account_deps": mut_output["account_parent_cfg"][0]["dependencies"],
        "pr_id": 1,
        "voters": ["success@simulator.amazonses.com"],
        "approval_voters": [],
        "min_approval_count": mut_output["account_parent_cfg"][0]["min_approval_count"],
        "rejection_voters": [],
        "min_rejection_count": mut_output["account_parent_cfg"][0][
            "min_rejection_count"
        ],
        "base_ref": mut_output["base_branch"],
        "head_ref": "feature-123",
    }
