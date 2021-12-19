INSERT INTO executions (
        execution_id,
        is_rollback,
        pr_id,
        commit_id,
        base_ref,
        head_ref,
        head_source_version,
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
        approval_count,
        min_approval_count,
        rejection_count,
        min_rejection_count
    )
SELECT
    'run-' || substr(md5(random()::text), 0, 8),
    false,
    {pr_id},
    {commit_id},
    {base_ref},
    {head_ref},
    'refs/pull/' || {pr_id} || '/head^{{' || {commit_id} || '}}',
    stack.cfg_path,
    stack.cfg_deps::TEXT[],
    'waiting',
    -- TODO: add user defined extra tf args from terraform module input
    'terragrunt plan --terragrunt-working-dir ' || stack.cfg_path,
    'terragrunt apply --terragrunt-working-dir ' || stack.cfg_path || ' -auto-approve',
    stack.new_providers::TEXT[], 
    ARRAY[]::TEXT[],
    account.account_name,
    account.account_path,
    account.account_deps,
    account.voters,
    0,
    account.min_approval_count,
    0,
    account.min_rejection_count
FROM (
    SELECT
        account_dim.account_name,
        account_dim.account_path,
        account_dim.account_deps,
        account_dim.voters,
        account_dim.min_approval_count,
        account_dim.min_rejection_count
    FROM account_dim
    WHERE account_dim.account_path = {account_path}
) account,
(
    SELECT * 
    FROM (VALUES %s) stack({cols})
) stack
RETURNING *;