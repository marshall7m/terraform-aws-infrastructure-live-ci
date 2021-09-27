#!/usr/bin/env bats

setup_file() {
    export script_logging_level="DEBUG"
    load 'common_setup.bash'

    _common_setup
    
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb

    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"
    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
    setup_test_file_tf_state "directory_dependency/dev-account"
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_metadb
    teardown_test_file_tmp_dir
}

setup() {
    setup_test_case_repo
    cd "$TEST_CASE_REPO_DIR"
    
    setup_test_case_tf_state

    run_only_test 1
}

teardown() {
    clear_metadb_tables
    drop_temp_tables
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    run mock_commit.bash
    assert_failure
}

@test "create commit with new provider and apply changes" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    modify_items=$(jq -n '
        [
            {
                "cfg_path": "directory_dependency/dev-account/global",
                "new_provider": true,
                "apply_changes": true
            }
        ]
    ')
    
    commit_items=$(jq -n '
        {
            "is_rollback": false,
            "status": "running"
        }
    ')

    run mock_commit.bash \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$modify_items" \
        --commit-item "$commit_items" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    assert_success

    commit_id=$(echo "$output" | jq '.commit.commit_id')
    cfg_path=$(echo "$output" | jq '.modify[0].cfg_path')
    is_rollback=$(echo "$output" | jq '.modify[0].is_rollback')
    new_resources=$(echo "$output" | jq 'modify.new_resources' | tr -d '"')

    cd "$TEST_CASE_REPO_DIR"

    assert_equal "$(echo "$output" | jq '.commit.commit_id')" "$(git log --pretty=format:'%H' -n 1)"

    
    # assert commit msg/base-ref are correct
    # assert if modify items are correct via git
    #assert commit queue item is correct
}
