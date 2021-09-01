export script_logging_level="DEBUG"
export MOCK_AWS_CMDS=true
export KEEP_METADB_OPEN=true

setup_file() {
    load 'test_helper/common-setup'
    load 'test_helper/repo'
    load 'test_helper/metadb'
    load 'test_helper/mock-tables'
    
    _common_setup
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb

    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_metadb
    teardown_tmp_dir
}

setup() {
    load 'test_helper/common-setup'
    load 'test_helper/repo'
    load 'test_helper/metadb'
    load 'test_helper/mock-tables'
    setup_test_case_repo

    create_testing_repo_tg_env \
        --modify-path "$TEST_CASE_REPO_DIR/directory_dependency/dev-account/us-west-2/env-one/bar"

    run_only_test "1"
}

teardown() {

    clear_metadb_tables
}

@test "Script is runnable" {
    run trigger_sf.sh
}

@test "Successful deployment event without new provider resources" {

    setup_mock_execution_table --uniq-base-ref --uniq-head-ref 
    sql="""
    INSERT INTO commit_queue (
        commit_id,
        pr_id,
        base_ref,
        head_ref, 
        status
    )

    SELECT
        RANDOM_STRING(8),
        RANDOM() * 2,
        'master',
        'feature-' || seq AS head_ref
    FROM GENERATE_SERIES(1, 10) seq;


    INSERT INTO executions (
        execution_id,
        pr_id,
        commit_id,
        is_rollback,
        cfg_path,
        account_dependencies,
        path_dependencies,
        execution_status,
        plan_command,
        deploy_command,
        new_providers,
        new_resources,
        account_name,
        account_path,
        voters,
        approval_count,
        min_approval_count,
        rejection_count,
        min_rejection_count
    )

    INSERT INTO account_dim (
        account_name,
        account_path,
        account_dependencies,
        min_approval_count,
        min_rejection_count,
        voters
    )

    SELECT
        RANDOM_STRING(4),
        RANDOM_STRING(4),
        (
            CASE is_rollback
            WHEN 0 THEN '[]'
            WHEN 1 THEN '[' || RANDOM_STRING(4) || ']'
            END
        ) as new_providers, 
        (
            CASE is_rollback
            WHEN 0 THEN '[]'
            WHEN 1 THEN '[' || RANDOM_STRING(4) || ']'
            END
        ) as new_resources,
        RANDOM() * 2,
        RANDOM() * 2,
        '[' || RANDOM_STRING(4) || ']'
    FROM GENERATE_SERIES(1, 3) seq;
    """

    query "$sql"
    
    export EVENTBRIDGE_EVENT=$(jq -n \
    --arg commit_id $(git rev-parse --verify HEAD) \
    --arg execution_id "$execution_id" '
        {
            "path": "test-path/",
            "execution_id": $execution_id,
            "deployment_type": "Deploy",
            "status": "SUCCESS",
            "commit_id": $commit_id
        } | tostring
    ')

    run trigger_sf.sh
    assert_success
}

@test "Successful deployment event and dequeue next deployment stack" {
}

@test "Successful deployment event and dequeue next PR" {
}

@test "Successful deployment event, deployment stack is finished, rollback is needed and run rollback stack" {
}

@test "Successful deployment event, deployment stack is not finished, rollback is needed, skip deployments" {
}


@test "Failed deployment event, deployment stack is finished, queue rollback commits, and run rollback commit stack" {
}

@test "Failed deployment event, deployment stack is not finished, skip deployments" {
}

@test "Successful rollback deployment event and dequeue next rollback stack" {
}

@test "Successful rollback deployment event and dequeue next PR" {
}
