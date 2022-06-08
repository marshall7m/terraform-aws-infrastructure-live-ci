-- noqa: disable=PRS,LXR,L013
INSERT INTO executions (
    execution_id,
    is_rollback,
    commit_id,
    base_ref,
    head_ref,
    cfg_path,
    cfg_deps,
    "status",
    new_providers,
    new_resources,
    account_name,
    account_path,
    account_deps,
    voters,
    approval_voters,
    min_approval_count,
    rejection_voters,
    min_rejection_count,
    plan_role_arn,
    deploy_role_arn,
    pr_id,
    plan_command,
    deploy_command
)
SELECT
    'run-' || {pr_id} || '-' || substring('{commit_id}', 1, 4) || '-' || a.account_name || '-' || regexp_replace(stack.cfg_path, '.*/', '') || '-' || substr(md5(random()::text), 0, 4) AS execution_id,
    FALSE,
    '{commit_id}',
    '{base_ref}',
    '{head_ref}',
    stack.cfg_path,
    stack.cfg_deps::TEXT[],
    'waiting',
    stack.new_providers::TEXT[],
    array[]::TEXT[], -- noqa: L027
    a.account_name,
    a.account_path,
    a.account_deps,
    a.voters,
    array[]::TEXT[],  -- noqa: L027
    a.min_approval_count,
    array[]::TEXT[],  -- noqa: L027
    a.min_rejection_count,
    a.plan_role_arn,
    a.deploy_role_arn,
    {pr_id},  -- noqa: L019
    'terragrunt plan --terragrunt-working-dir ' || stack.cfg_path
    || ' --terragrunt-iam-role ' || a.plan_role_arn,
    'terragrunt apply --terragrunt-working-dir ' || stack.cfg_path
    || ' --terragrunt-iam-role ' || a.deploy_role_arn || ' -auto-approve'
FROM (
    SELECT
        account_dim.account_name,
        account_dim.account_path,
        account_dim.account_deps,
        account_dim.voters,
        account_dim.min_approval_count,
        account_dim.min_rejection_count,
        account_dim.plan_role_arn,
        account_dim.deploy_role_arn
    FROM account_dim
    WHERE account_dim.account_path = '{account_path}'
) AS a,
(
    SELECT
        :cfg_path,  -- noqa: L019
        string_to_array(:cfg_deps, ','),
        string_to_array(:new_providers, ',')
) AS stack(cfg_path, cfg_deps, new_providers)*;
