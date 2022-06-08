-- noqa: disable=PRS,LXR
INSERT INTO ${metadb_schema}.account_dim
VALUES (
    :account_name,
    :account_path,
    CAST(:account_deps AS VARCHAR[]),
    :min_approval_count,
    :min_rejection_count,
    CAST(:voters AS VARCHAR[]),
    :plan_role_arn,
    :deploy_role_arn
)
ON CONFLICT (account_name) DO UPDATE SET
    account_path = EXCLUDED.account_path,
    account_deps = EXCLUDED.account_deps,
    min_approval_count = EXCLUDED.min_approval_count,
    min_rejection_count = EXCLUDED.min_rejection_count,
    voters = EXCLUDED.voters,
    plan_role_arn = EXCLUDED.plan_role_arn,
    deploy_role_arn = EXCLUDED.deploy_role_arn
