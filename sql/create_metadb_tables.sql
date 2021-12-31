CREATE TABLE IF NOT EXISTS executions (
    execution_id VARCHAR PRIMARY KEY,
    is_rollback BOOL,
    pr_id INT,
    commit_id VARCHAR,
    base_ref VARCHAR,
    head_ref VARCHAR,
    head_source_version VARCHAR,
    cfg_path VARCHAR,
    cfg_deps TEXT[],
    "status" VARCHAR,
    plan_command TEXT,
    deploy_command TEXT,
    new_providers TEXT[],
    new_resources TEXT[],
    account_name VARCHAR,
    account_path VARCHAR,
    account_deps TEXT[],
    voters TEXT[],
    approval_voters TEXT[],
    approval_count INT CHECK (approval_count >= 0) GENERATED ALWAYS AS (cardinality(approval_voters)) STORED,
    min_approval_count INT CHECK (min_approval_count >= 0),
    rejection_voters TEXT[],
    rejection_count INT CHECK (rejection_count >= 0) GENERATED ALWAYS AS (cardinality(rejection_voters)) STORED,
    min_rejection_count INT CHECK (min_rejection_count >= 0)
);

CREATE TABLE IF NOT EXISTS account_dim (
    account_name VARCHAR PRIMARY KEY,
    account_path VARCHAR,
    account_deps TEXT[],
    min_approval_count INT,
    min_rejection_count INT,
    voters TEXT[]
);