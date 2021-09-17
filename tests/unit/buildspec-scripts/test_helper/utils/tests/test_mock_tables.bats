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

@test "Mock pr queue records" {
    expected=$(jq -n '{"pr_id": 1}')
    run mock_tables.bash --table "pr_queue" --random-defaults --items "$expected" --count 5
    assert_failure

    run query -c "SELECT * FROM pr_queue;"
    assert_failure
}