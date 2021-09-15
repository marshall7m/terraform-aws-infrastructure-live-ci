load '../../bats-support/load'
load '../../bats-assert/load'
load '../load.bash'

setup_file() {
    export script_logging_level="DEBUG"
    export KEEP_METADB_OPEN=true
    export METADB_TYPE=local

    load './load.bash'

    _common_setup
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb

    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"
    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
    # setup_test_file_tf_state "directory_dependency/dev-account"
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_metadb
    teardown_test_file_tmp_dir
}

setup() {
    setup_test_case_repo
    # setup_test_case_tf_state

    run_only_test 2
}

teardown() {
    clear_metadb_tables
    drop_mock_temp_tables
    drop_temp_tables
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    run mock_tables.bash
}

@test "Create staging_cfg_stack and account dim tables" {
    account_dim=$(jq -n '
    [
        {
            "account_name": "dev",
            "account_path": "directory_dependency/dev-account",
            "account_deps": [],
            "min_approval_count": 1,
            "min_rejection_count": 1,
            "voters": ["voter-1"]
        }
    ]
    ')
    run mock_tables.bash --account-dim "$account_dim" --based-on-tg-dir "$TEST_CASE_REPO_DIR/directory_dependency" --git-root "$TEST_CASE_REPO_DIR"
    assert_success

    log "$(query --psql-extra-args "-x" "SELECT * FROM mock_staging_cfg_stack;")" "DEBUG"
    run query """
    do \$\$
        BEGIN
            ASSERT (
                SELECT 
                    COUNT(*)
                FROM 
                    mock_staging_cfg_stack
            ) >= 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}


@test "Mock pr queue records" {
    run mock_tables.bash --table "pr_queue" --status "running"
}