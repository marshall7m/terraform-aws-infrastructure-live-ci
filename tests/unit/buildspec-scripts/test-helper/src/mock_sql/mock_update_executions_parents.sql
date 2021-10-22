INSERT INTO pr_queue (
    pr_id,
    base_ref,
    head_ref,
    "status"
)
SELECT
    pr_id,
    base_ref,
    head_ref,
    "status"
FROM executions
ON CONFLICT DO NOTHING;

INSERT INTO commit_queue (
    commit_id,
    is_rollback,
    is_base_rollback,
    pr_id,
    "status"
)
SELECT
    commit_id,
    is_rollback,
    is_base_rollback,
    pr_id,
    "status"
FROM executions
ON CONFLICT DO NOTHING;

INSERT INTO account_dim (
    account_name,
    account_path,
    account_deps,
    min_approval_count,
    min_rejection_count,
    voters
)
SELECT
    account_name,
    account_path,
    account_deps,
    min_approval_count,
    min_rejection_count,
    voters
FROM executions
ON CONFLICT DO NOTHING;
