CREATE TABLE IF NOT EXISTS executions (
    execution_id VARCHAR PRIMARY KEY,
    is_rollback BOOL,
    is_base_rollback BOOL,
    pr_id INT,
    commit_id VARCHAR,
    base_ref VARCHAR,
    head_ref VARCHAR,
    base_source_version VARCHAR,
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
    approval_count INT CHECK (approval_count >= 0),
    min_approval_count INT CHECK (min_approval_count >= 0),
    rejection_count INT CHECK (rejection_count >= 0),
    min_rejection_count INT CHECK (min_rejection_count >= 0)
);

CREATE TABLE IF NOT EXISTS pr_queue (
    id INT GENERATED ALWAYS AS IDENTITY,
    pr_id INT,
    status VARCHAR,
    base_ref VARCHAR,
    head_ref VARCHAR,
    PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS commit_queue (
    id INT GENERATED ALWAYS AS IDENTITY,
    commit_id VARCHAR,
    is_rollback BOOL,
    is_base_rollback BOOL,
    pr_id INT,
    status VARCHAR,
    PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS account_dim (
    account_name VARCHAR PRIMARY KEY,
    account_path VARCHAR,
    account_deps TEXT[],
    min_approval_count INT,
    min_rejection_count INT,
    voters TEXT[]
);