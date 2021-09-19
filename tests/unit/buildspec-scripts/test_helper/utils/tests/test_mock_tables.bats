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

    run_only_test 3
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

@test "Mock pr queue records based on object" {
    pr_id=1
    count=5
    expected=$(jq -n --arg pr_id $pr_id '{"pr_id": ($pr_id | tonumber)}')
    init_count=$(query -qtAX -c "SELECT COUNT(*) FROM pr_queue WHERE pr_id = $pr_id")

    run mock_tables.bash --table "pr_queue" --random-defaults --items "$expected" --count "$count"
    assert_success
    
    log "$(query -c "SELECT * FROM pr_queue;")" "DEBUG"

    run query -c """ 
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM pr_queue 
                WHERE pr_id = $pr_id
            ) = $(($count + $init_count));
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}

@test "Mock commit queue records based on object" {
    pr_id=1
    count=5
    expected=$(jq -n --arg pr_id $pr_id '{"pr_id": ($pr_id | tonumber)}')
    init_count=$(query -qtAX -c "SELECT COUNT(*) FROM commit_queue WHERE pr_id = $pr_id")

    run mock_tables.bash --table "commit_queue" --random-defaults --items "$expected" --count "$count" --update-parents
    assert_success
    
    log "$(query -c "SELECT * FROM commit_queue;")" "DEBUG"

    run query -c """ 
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM commit_queue 
                WHERE pr_id = $pr_id
            ) = $(($count + $init_count));
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success

    log "Assert all commit queue PR IDs are within pr_queue" "DEBUG"

    log "commit_queue:" "DEBUG"
    log "$(query -c "SELECT DISTINCT pr_id FROM commit_queue;")" "DEBUG"

    log "pr_queue:" "DEBUG"
    
    log "$(query -c "SELECT DISTINCT pr_id FROM pr_queue;")" "DEBUG"
    run query -c """ 
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM (
                    SELECT DISTINCT pr_id
                    FROM commit_queue 
                ) commit
            ) = (
                SELECT COUNT(*)
                FROM (
                    SELECT DISTINCT pr_id
                    FROM pr_queue 
                ) pr
            );
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}