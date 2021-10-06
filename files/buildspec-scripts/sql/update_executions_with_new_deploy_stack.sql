INSERT INTO executions
SELECT
    'run-' || substr(md5(random()::text), 0, 8) as execution_id,
    false as is_rollback,
    commit.pr_id as pr_id,
    commit.commit_id as commit_id,
    'refs/heads/:'base_ref'^{:'base_commit_id'}' as base_source_version,
    'refs/pull/' || commit.pr_id || '/head^{' || commit.commit_id || '}' as head_source_version,
    cfg_path as cfg_path,
    cfg_deps as cfg_deps,
    'waiting' as "status",
    'terragrunt plan ' || '--terragrunt-working-dir ' || stack.cfg_path as plan_command,
    'terragrunt apply ' || '--terragrunt-working-dir ' || stack.cfg_path || ' -auto-approve' as deploy_command,
    new_providers as new_providers, 
    ARRAY[NULL] as new_resources,
    account.account_name as account_name,
    account.account_path as account_path,
    account.account_deps as account_deps,
    account.voters as voters,
    0 as approval_count,
    account.min_approval_count as min_approval_count,
    0 as rejection_account,
    account.min_rejection_count as min_rejection_count
FROM (
    SELECT
        pr_id,
        commit_id
    FROM commit_queue
    WHERE commit_id = :'commit_id'
) "commit",
(
    SELECT
        account_name,
        account_path,
        account_deps,
        voters,
        min_approval_count,
        min_rejection_count
    FROM account_dim
    WHERE account_path = :'account_path'
) account,
(
    SELECT *
    FROM staging_cfg_stack
) stack
RETURNING *;