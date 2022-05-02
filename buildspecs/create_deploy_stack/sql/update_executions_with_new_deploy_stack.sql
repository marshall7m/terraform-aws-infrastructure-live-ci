INSERT INTO executions (
        execution_id,
        is_rollback,
        pr_id,
        commit_id,
        base_ref,
        head_ref,
        cfg_path,
        cfg_deps,
        "status",
        plan_command,
        deploy_command,
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
        deploy_role_arn
    )
SELECT
    'run-' || {pr_id} || '-' || substring('{commit_id}', 1, 4) || '-' || a.account_name || '-' || regexp_replace(stack.cfg_path, '.*/', '') || '-'  || substr(md5(random()::text), 0, 4),
    false,
    {pr_id},
    '{commit_id}',
    '{base_ref}',
    '{head_ref}',
    stack.cfg_path,
    stack.cfg_deps::TEXT[],
    'waiting',
    'terragrunt plan --terragrunt-working-dir ' || stack.cfg_path || ' --terragrunt-iam-role ' || a.plan_role_arn,
    'terragrunt apply --terragrunt-working-dir ' || stack.cfg_path || ' --terragrunt-iam-role ' || a.deploy_role_arn || ' -auto-approve',
    stack.new_providers::TEXT[], 
    ARRAY[]::TEXT[],
    a.account_name,
    a.account_path,
    a.account_deps,
    a.voters,
    ARRAY[]::TEXT[],
    a.min_approval_count,
    ARRAY[]::TEXT[],
    a.min_rejection_count,
    a.plan_role_arn,
    a.deploy_role_arn
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
) a,
(
    SELECT :cfg_path, string_to_array(:cfg_deps, ','), string_to_array(:new_providers, ',')
) stack(cfg_path, cfg_deps, new_providers)
RETURNING *;