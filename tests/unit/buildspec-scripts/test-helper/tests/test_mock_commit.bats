#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../../node_modules/bash-utils/load.bash"
load "${BATS_TEST_DIRNAME}/../../../node_modules/bats-utils/load.bash"

load "${BATS_TEST_DIRNAME}/../../../node_modules/bats-support/load.bash"
load "${BATS_TEST_DIRNAME}/../../../node_modules/bats-assert/load.bash"

load "${BATS_TEST_DIRNAME}/../../../node_modules/psql-utils/load.bash"

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

    commit_id=$(echo "$output" | jq -r '.commit.commit_id')
    pr_id=$(echo "$output" | jq -r '.commit.pr_id')
    cfg_path=$(echo "$output" | jq -r '.modify[0].cfg_path')
    is_rollback=$(echo "$output" | jq -r '.modify[0].is_rollback')
    new_resources=$(echo "$output" | jq -r 'modify.new_resources')

    log "Assert mock commit record was added to the commit_queue" "INFO"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM commit_queue
                WHERE pr_id = '$pr_id'
                AND commit_Id = '$commit_id'
                AND is_rollback = '$is_rollback'
                AND status = '$status'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success

    log "Assert pr_queue was updated with commit's associated PR ID" "INFO"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM pr_queue
                WHERE pr_id = '$pr_id'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
    
}
