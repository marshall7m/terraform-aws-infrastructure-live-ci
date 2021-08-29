#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB"  \
    --variable=POSTGRES_USER="$TESTING_POSTGRES_USER" \
    --variable=POSTGRES_DB="$TESTING_POSTGRES_DB" <<-EOSQL
    CREATE USER :POSTGRES_USER;
    CREATE DATABASE :POSTGRES_DB;
    GRANT ALL PRIVILEGES ON DATABASE :POSTGRES_DB TO :POSTGRES_USER;
    
    \c :POSTGRES_DB 
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO :POSTGRES_USER;
    
    set plpgsql.check_asserts to on;

    SET SESSION ROLE :POSTGRES_USER;
    CREATE TABLE IF NOT EXISTS executions (
        execution_id INT PRIMARY KEY,
        pr_id VARCHAR,
        commit_id VARCHAR,
        execution_type VARCHAR,
        target_path VARCHAR,
        account_dependencies VARCHAR,
        path_dependencies VARCHAR,
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


    CREATE TABLE IF NOT EXISTS commit_queue (
        commit_id VARCHAR PRIMARY KEY,
        pr_id INT,
        commit_status VARCHAR,
        base_ref VARCHAR,
        head_ref VARCHAR,
        execution_type VARCHAR
    );

    CREATE TABLE IF NOT EXISTS account_dim (
        account_name VARCHAR PRIMARY KEY,
        account_path VARCHAR,
        account_dependencies VARCHAR,
        min_approval_count INT,
        min_rejection_count INT,
        voters VARCHAR
    );
EOSQL


