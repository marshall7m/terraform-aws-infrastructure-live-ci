#!/bin/bash

psql_db_is_running() {
    find -name .s.PGSQL.5432 | grep .
    return $?
} 

psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB"  \
    --variable=POSTGRES_USER="$POSTGRES_USER" \
    --variable=TESTING_POSTGRES_USER="$TESTING_POSTGRES_USER" \
    --variable=TESTING_POSTGRES_DB="$TESTING_POSTGRES_DB" <<-EOSQL
    CREATE USER :TESTING_POSTGRES_USER;
    GRANT :POSTGRES_USER to :TESTING_POSTGRES_USER;
    CREATE DATABASE :TESTING_POSTGRES_DB;
    GRANT ALL PRIVILEGES ON DATABASE :TESTING_POSTGRES_DB TO :TESTING_POSTGRES_USER;

    \c :TESTING_POSTGRES_DB
    
    set plpgsql.check_asserts to on;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO :TESTING_POSTGRES_USER;

    SET ROLE :TESTING_POSTGRES_USER;
    
    CREATE TABLE IF NOT EXISTS executions (
        execution_id VARCHAR PRIMARY KEY,
        is_rollback BOOL,
        pr_id VARCHAR,
        commit_id VARCHAR,
        cfg_path VARCHAR,
        cfg_deps TEXT[],
        execution_status VARCHAR,
        plan_command VARCHAR,
        deploy_command VARCHAR,
        new_providers TEXT[],
        new_resources TEXT[],
        account_name VARCHAR,
        account_deps TEXT[],
        account_path VARCHAR,
        voters TEXT[],
        approval_count INT CHECK (approval_count >= 0),
        min_approval_count INT CHECK (min_approval_count >= 0),
        rejection_count INT CHECK (rejection_count >= 0),
        min_rejection_count INT CHECK (min_rejection_count >= 0)
    );


    CREATE TABLE IF NOT EXISTS pr_queue (
        pr_id INT,
        status VARCHAR,
        base_ref VARCHAR,
        head_ref VARCHAR
    );

    CREATE TABLE IF NOT EXISTS commit_queue (
        commit_id VARCHAR,
        is_rollback BOOL,
        pr_id INT,
        status VARCHAR    
    );

    CREATE TABLE IF NOT EXISTS account_dim (
        account_name VARCHAR PRIMARY KEY,
        account_path VARCHAR,
        account_deps TEXT[],
        min_approval_count INT,
        min_rejection_count INT,
        voters TEXT[]
    );
EOSQL