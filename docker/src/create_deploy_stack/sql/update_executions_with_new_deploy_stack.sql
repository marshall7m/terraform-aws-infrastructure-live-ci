-- noqa: disable=PRS,LXR,L013
INSERT INTO executions (
    execution_id,
    is_rollback,
    commit_id,
    base_ref,
    head_ref,
    cfg_path,
    cfg_deps,
    "status",  -- noqa: L059
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
    apply_role_arn,
    pr_id,
    plan_command,
    apply_command
)
SELECT  -- noqa: L034, L036
    'run-' || {pr_id} || '-' || substring('{commit_id}', 1, 4) || '-' || '{account_name}' || '-' || regexp_replace(stack.cfg_path, '.*/', '') || '-' || substr(md5(random()::text), 0, 4) AS execution_id,
    FALSE,
    '{commit_id}',
    '{base_ref}',
    '{head_ref}',
    stack.cfg_path,
    string_to_array(stack.cfg_deps, ',')::TEXT[],
    'waiting',
    string_to_array(stack.new_providers, ',')::TEXT[],
    array[]::TEXT[], -- noqa: L027, L019
    '{account_name}',
    '{account_path}',
    string_to_array('{account_deps}', ','),
    string_to_array('{voters}', ','),
    array[]::TEXT[],  -- noqa: L027, L019
    {min_approval_count},
    array[]::TEXT[],  -- noqa: L027, L019
    {min_rejection_count},
    '{plan_role_arn}',
    '{apply_role_arn}',
    {pr_id},  -- noqa: L019
    'terragrunt plan --terragrunt-working-dir ' || stack.cfg_path
    || ' --terragrunt-iam-role ' || '{plan_role_arn}',
    'terragrunt apply --terragrunt-working-dir ' || stack.cfg_path
    || ' --terragrunt-iam-role ' || '{apply_role_arn}' || ' -auto-approve'
FROM (
    VALUES {stack}
) stack(cfg_path, cfg_deps, new_providers)  -- noqa: L011, L025
RETURNING *;
