import pytest
import os
import json
import logging

log = logging.getLogger(__file__)
log.setLevel(logging.DEBUG)


@pytest.fixture
def mock_sf_cfg(mut_output):
    """
    Overwrites Step Function State Machine placeholder name with name from Terraform module.
    See here for more info on mock config file:
    https://docs.aws.amazon.com/step-functions/latest/dg/sfn-local-mock-cfg-file.html
    """
    log.info(
        "Replacing placholder state machine name with: "
        + mut_output["step_function_name"]
    )
    mock_path = os.path.join(os.path.dirname(__file__), "mock_sf_cfg.json")
    with open(mock_path, "r") as f:
        cfg = json.load(f)

    cfg["StateMachines"][mut_output["step_function_name"]] = cfg["StateMachines"].pop(
        "Placeholder"
    )

    with open(mock_path, "w") as f:
        json.dump(cfg, f)

    yield mock_path

    log.info("Replacing state machine name back with placholder")
    with open(mock_path, "r") as f:
        cfg = json.load(f)

    cfg["StateMachines"]["Placeholder"] = cfg["StateMachines"].pop(
        mut_output["step_function_name"]
    )

    with open(mock_path, "w") as f:
        json.dump(cfg, f, indent=4, sort_keys=True)


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
