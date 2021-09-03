#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB"  \
    --variable=TESTING_POSTGRES_USER="$TESTING_POSTGRES_USER" \
    --variable=TESTING_POSTGRES_DB="$TESTING_POSTGRES_DB" <<-EOSQL
    CREATE USER :TESTING_POSTGRES_USER;
    CREATE DATABASE :TESTING_POSTGRES_DB;
    GRANT ALL PRIVILEGES ON DATABASE :TESTING_POSTGRES_DB TO :TESTING_POSTGRES_USER;

    \c :TESTING_POSTGRES_DB
    
    set plpgsql.check_asserts to on;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO :TESTING_POSTGRES_USER;

    SET ROLE :TESTING_POSTGRES_USER;
    
    CREATE TABLE IF NOT EXISTS executions (
        execution_id INT PRIMARY KEY,
        is_rollback BOOL,
        pr_id VARCHAR,
        commit_id VARCHAR,
        target_path VARCHAR,
        account_deps VARCHAR,
        path_deps VARCHAR,
        execution_status VARCHAR,
        plan_command VARCHAR,
        deploy_command VARCHAR,
        new_providers VARCHAR,
        new_resources VARCHAR,
        account_name VARCHAR,
        account_path VARCHAR,
        voters VARCHAR,
        approval_count INTEGER CHECK (approval_count >= 0),
        min_approval_count INTEGER CHECK (min_approval_count >= 0),
        rejection_count INTEGER CHECK (rejection_count >= 0),
        min_rejection_count INTEGER CHECK (min_rejection_count >= 0)
    );


    CREATE TABLE IF NOT EXISTS pr_queue (
        pr_id INT PRIMARY KEY,
        status VARCHAR,
        base_ref VARCHAR,
        head_ref VARCHAR,
    );

    CREATE TABLE IF NOT EXISTS commit_queue (
        commit_id VARCHAR,
        is_rollback BOOL,
        pr_id INT,
        status VARCHAR,
        PRIMARY KEY (commit_id, is_rollback)
    );

    CREATE TABLE IF NOT EXISTS account_dim (
        account_name VARCHAR PRIMARY KEY,
        account_path VARCHAR,
        account_deps VARCHAR,
        min_approval_count INT,
        min_rejection_count INT,
        voters VARCHAR
    );
EOSQL


