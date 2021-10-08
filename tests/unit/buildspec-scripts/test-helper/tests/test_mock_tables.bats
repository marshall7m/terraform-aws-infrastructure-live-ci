#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../load.bash"
load "${BATS_TEST_DIRNAME}/../../../../../node_modules/bash-utils/load.bash"
load "${BATS_TEST_DIRNAME}/../../../../../node_modules/bats-utils/load.bash"

load "${BATS_TEST_DIRNAME}/../../../../../node_modules/bats-support/load.bash"
load "${BATS_TEST_DIRNAME}/../../../../../node_modules/bats-assert/load.bash"

load "${BATS_TEST_DIRNAME}/../../../../../node_modules/psql-utils/load.bash"

setup_file() {
    export script_logging_level="DEBUG"
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    load './common_setup.bash'
    _common_setup
    
    setup_metadb
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_test_file_tmp_dir
}

setup() {    
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    # run_only_test 2
}

teardown() {
    clear_metadb_tables
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    run mock_tables.bash
}

@test "Mock account dim records based on object" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
    
    account_name=dev
    expected=$(jq -n --arg account_name "$account_name" '{"account_name": $account_name}')

    run mock_tables.bash --table "account_dim" --enable-defaults --items "$expected"
    assert_success

    log "$(psql -c "SELECT * FROM account_dim;")" "DEBUG"

    run psql -c """ 
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM account_dim 
                WHERE account_name = '$account_name'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}


@test "Mock pr queue records based on object" {
    pr_id=1
    count=5
    expected=$(jq -n --arg pr_id $pr_id '{"pr_id": ($pr_id | tonumber)}')
    init_count=$(psql -qtAX -c "SELECT COUNT(*) FROM pr_queue WHERE pr_id = $pr_id")

    run mock_tables.bash --table "pr_queue" --enable-defaults --items "$expected" --count "$count" --reset-identity-col
    assert_success
    
    log "$(psql -c "SELECT * FROM pr_queue;")" "DEBUG"

    run psql -c """ 
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
    init_count=$(psql -qtAX -c "SELECT COUNT(*) FROM commit_queue WHERE pr_id = $pr_id")

    run mock_tables.bash --table "commit_queue" --enable-defaults --items "$expected" --count "$count" --update-parents --reset-identity-col
    assert_success
    
    log "$(psql -c "SELECT * FROM commit_queue;")" "DEBUG"

    run psql -c """ 
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
    log "$(psql -c "SELECT DISTINCT pr_id FROM commit_queue;")" "DEBUG"

    log "pr_queue:" "DEBUG"

    log "$(psql -c "SELECT DISTINCT pr_id FROM pr_queue;")" "DEBUG"
    run psql -c """ 
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

@test "Mock executions records based on object" {
    pr_id=1
    count=5
    init_count=$(psql -qtAX -c "SELECT COUNT(*) FROM executions WHERE pr_id = $pr_id")

    expected=$(jq -n --arg pr_id $pr_id '{"pr_id": ($pr_id | tonumber)}')
    expected_count=$(($count + $init_count))

    run mock_tables.bash --table "executions" --enable-defaults --items "$expected" --count "$count" --update-parents
    assert_success
    
    log "$(psql -x -c "SELECT * FROM executions;")" "DEBUG"
    log "$(psql -x -c "SELECT COUNT(*) FROM executions;")" "DEBUG"

    run psql -c """ 
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM executions 
                WHERE pr_id = '$pr_id'
            ) = $expected_count;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}