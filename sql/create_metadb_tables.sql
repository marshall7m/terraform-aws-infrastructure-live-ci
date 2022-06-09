-- noqa: disable=PRS,LXR
CREATE SCHEMA IF NOT EXISTS ${metadb_schema};
ALTER DATABASE ${metadb_name} SET search_path TO ${metadb_schema};

SET search_path = ${metadb_schema};

CREATE TABLE IF NOT EXISTS executions (
    execution_id VARCHAR PRIMARY KEY,
    is_rollback BOOL,
    pr_id INT,
    commit_id VARCHAR,
    base_ref VARCHAR,
    head_ref VARCHAR,
    cfg_path VARCHAR,
    cfg_deps TEXT[],
    "status" VARCHAR,  -- noqa: L059
    plan_command TEXT,
    deploy_command TEXT,
    new_providers TEXT[],
    new_resources TEXT[],
    account_name VARCHAR,
    account_path VARCHAR,
    account_deps TEXT[],
    voters TEXT[],
    approval_voters TEXT[],
    min_approval_count INT CHECK (min_approval_count >= 0),
    rejection_voters TEXT[],
    min_rejection_count INT CHECK (min_rejection_count >= 0),
    plan_role_arn VARCHAR,
    deploy_role_arn VARCHAR
);

CREATE TABLE IF NOT EXISTS account_dim (
    account_name VARCHAR PRIMARY KEY,
    account_path VARCHAR,
    account_deps TEXT[],
    min_approval_count INT,
    min_rejection_count INT,
    voters TEXT[],
    plan_role_arn VARCHAR,
    deploy_role_arn VARCHAR
);
