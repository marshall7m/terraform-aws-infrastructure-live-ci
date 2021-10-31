INSERT INTO pr_queue (id, pr_id, base_ref, head_ref, "status")
OVERRIDING SYSTEM VALUE
SELECT
    coalesce(id, nextval('pr_queue_id_seq')) AS id,
    e.pr_id,
    e.base_ref,
    e.head_ref,
    e."status"
FROM (
    SELECT
        pr_id,
        base_ref,
        head_ref,
        "status"
    FROM executions
) e
LEFT JOIN pr_queue p
ON (
    e.pr_id = p.pr_id
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO commit_queue (id, commit_id, is_rollback, is_base_rollback, pr_id, "status")
OVERRIDING SYSTEM VALUE
SELECT
    coalesce(id, nextval('commit_queue_id_seq')) AS id,
    e.commit_id,
    e.is_rollback,
    e.is_base_rollback,
    e.pr_id,
    e."status"
FROM (
    SELECT
        commit_id,
        is_rollback,
        is_base_rollback,
        pr_id,
        "status"
    FROM executions
) e
LEFT JOIN commit_queue c
ON (
    e.commit_id = c.commit_id
)
ON CONFLICT (id) DO NOTHING;

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
ON CONFLICT (account_name) DO NOTHING;
