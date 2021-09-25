#!/usr/bin/env bats

setup_file() {
    load 'test-helper/bats-support/load'
    load 'test-helper/bats-assert/load'

    export script_logging_level="DEBUG"

    export BASE_REF=master
    export CODEBUILD_INITIATOR=rule/test
    export EVENTBRIDGE_FINISHED_RULE=rule/test
    source mock_aws_cmds.sh

    load 'test-helper/load.bash'

    _common_setup
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb

    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"
    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
    setup_test_file_tf_state "directory_dependency/dev-account"
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_test_file_tmp_dir
}

setup() {
    load 'test-helper/load.bash'

    setup_test_case_repo
    setup_test_case_tf_state

    run_only_test 3
}

teardown() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    clear_metadb_tables
    drop_temp_tables
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    run trigger_sf.sh
}

@test "Successful deployment event with new provider resources, dequeue deploy commit with no new providers" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
    
    modify_items=$(jq -n '
        [
            {
                "cfg_path": "directory_dependency/dev-account/global",
                "new_provider": true,
                "apply_changes": false
            }
        ]
    ')
    
    commit_items=$(jq -n '
        {
            "is_rollback": false,
            "status": "running"
        }
    ')

    cw_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$modify_items" \
        --commit-item "$commit_items" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    finished_execution=$(jq -n \
        --arg execution_id "$execution_id" \
        --arg cfg_path "$testing_dir" \
        --arg commit_id "$commit_id" \
        --arg new_providers "$new_providers" '
        {
            "cfg_path": $cfg_path,
            "commit_id": $commit_id,
            "new_providers": $new_providers
        }
    ')

    finished_status="success"

    mock_cloudwatch_execution "$finished_execution" "$finished_status" 

    log "Creating mock account_dim" "INFO"

    account_dim=$(jq -n '
        {
            "account_path": "directory_dependency/dev-account",
            "account_deps": [],
        }
    ')

    mock_table --table "account_dim" --items "$account_dim" --random-defaults

    modify_items=$(jq -n '
        [
            {
                "cfg_path": "directory_dependency/dev-account/env-one/doo",
                "new_provider": false,
                "apply_changes": false
            }
        ]
    ')

    commit_items=$(jq -n '
        {
            "is_rollback": false,
            "status": "waiting"
        }
    ')

    target_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$modify_items" \
        --commit-item "$commit_items" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    run trigger_sf.sh
    assert_success

    log "Assert mock Cloudwatch event for step function execution has updated execution status" "INFO"
    execution_id=$(echo "$EVENTBRIDGE_EVENT" | jq '.execution_id' | tr -d '"')
    new_resources=$(echo "$target_commit" | jq 'modify.new_resources' | tr -d '"')

    log "$(psql -x "select * from executions where execution_id = '$execution_id';")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT 
                    COUNT(*)
                FROM 
                    executions
                WHERE
                    execution_id = '$execution_id' 
                AND
                    new_resources = ARRAY['$new_resources']
                AND
                    status = 'success'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success

    log "Assert mock commit for step function execution has been dequeued by having a running status" "INFO"

    commit_id=$(echo "$target_commit" | jq '.commit.commit_id')
    cfg_path=$(echo "$target_commit" | jq '.modify[0].cfg_path')
    is_rollback=$(echo "$target_commit" | jq '.modify[0].is_rollback')

    log "$(psql -x "select * from executions where commit_id = '$commit_id';")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT
                    COUNT(*)
                FROM
                    executions
                WHERE
                    commit_id = '$commit_id' 
                AND
                    cfg_path = '$cfg_path' 
                AND
                    is_rollback = '$is_rollback' 
                AND
                    status = 'running'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}

@test "Successful deployment event with no new provider resources, dequeue deploy commit with new providers" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
    
    modify_items=$(jq -n '
        [
            {
                "cfg_path": "directory_dependency/dev-account/global",
                "new_provider": false,
                "apply_changes": false
            }
        ]
    ')
    
    commit_items=$(jq -n '
        {
            "is_rollback": false,
            "status": "running"
        }
    ')

    cw_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$modify_items" \
        --commit-item "$commit_items" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    finished_execution=$(jq -n \
        --arg execution_id "$execution_id" \
        --arg cfg_path "$testing_dir" \
        --arg commit_id "$commit_id" \
        --arg new_providers "$new_providers" '
        {
            "cfg_path": $cfg_path,
            "commit_id": $commit_id,
            "new_providers": $new_providers
        }
    ')

    finished_status="success"

    mock_cloudwatch_execution "$finished_execution" "$finished_status" 

    log "Creating mock account_dim" "INFO"

    account_dim=$(jq -n '
        {
            "account_path": "directory_dependency/dev-account",
            "account_deps": [],
        }
    ')

    mock_table --table "account_dim" --items "$account_dim" --random-defaults

    modify_items=$(jq -n '
        [
            {
                "cfg_path": "directory_dependency/dev-account/env-one/doo",
                "new_provider": true,
                "apply_changes": false
            }
        ]
    ')

    commit_items=$(jq -n '
        {
            "is_rollback": false,
            "status": "waiting"
        }
    ')

    target_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$modify_items" \
        --commit-item "$commit_items" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    run trigger_sf.sh
    assert_success

    log "Assert mock Cloudwatch event for step function execution has updated execution status" "INFO"
    execution_id=$(echo "$EVENTBRIDGE_EVENT" | jq '.execution_id' | tr -d '"')

    log "$(psql -x "select * from executions where execution_id = '$execution_id';")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT 
                    COUNT(*)
                FROM 
                    executions
                WHERE
                    execution_id = '$execution_id' 
                AND
                    new_resources = '{}'
                AND
                    status = 'success'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success

    log "Assert mock commit for step function execution has been dequeued by having a running status" "INFO"
    
    commit_id=$(echo "$target_commit" | jq '.commit.commit_id')
    cfg_path=$(echo "$target_commit" | jq '.modify[0].cfg_path')
    is_rollback=$(echo "$target_commit" | jq '.modify[0].is_rollback')
    new_resources=$(echo "$target_commit" | jq 'modify.new_resources' | tr -d '"')

    log "$(psql -x "select * from executions where commit_id = '$commit_id';")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT
                    COUNT(*)
                FROM
                    executions
                WHERE
                    commit_id = '$commit_id' 
                AND
                    cfg_path = '$cfg_path' 
                AND
                    is_rollback = '$is_rollback' 
                AND
                    status = 'running'
                AND
                    new_resources = ARRAY['$new_resources']
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}


@test "Successful deployment event, commit deployment stack is finished and contains new providers and rollback is needed" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    execution_id="run-0000001"
    running_execution=$(jq -n \
    --arg execution_id "$execution_id" '
    {
        "execution_id": $execution_id
    }
    ')

    mock_cloudwatch_execution "$running_execution" "success"

    log "Creating mock account_dim" "INFO"
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

    jq_to_psql_records "$account_dim" "account_dim"

    log "Modifying Terragrunt directory within test repo's base branch" "DEBUG"
    res=$(modify_tg_path --path "$abs_testing_dir" --new-provider-resource)
    mock_provider=$(echo "$res" | jq 'keys')
    mock_resource=$(echo "$res" | jq 'map(.resource) | join(", ")' | tr -d '"')
    
    log "Committing modifications and adding commit to commit queue" "DEBUG"
    add_test_case_head_commit_to_finished_execution
    
    log "Switching back to default branch" "DEBUG"
    git checkout "$(git remote show $(git remote) | sed -n '/HEAD branch/s/.*: //p')"
    
    run trigger_sf.sh
    assert_success

    log "Assert mock commit rollback is running" "INFO"
    log "$(psql -x "select * from commit_queue where commit_id = '$TESTING_COMMIT_ID';")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT
                    COUNT(*)
                FROM
                    commit_queue
                WHERE
                    commit_id = '$TESTING_COMMIT_ID'
                AND
                    is_rollback = true
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success

    log "Assert mock commit rollback executions are created" "INFO"
    log "$(psql -x "select * from executions where commit_id = '$TESTING_COMMIT_ID' AND is_rollback = true;")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT
                    COUNT(*)
                FROM
                    commit_queue
                WHERE
                    commit_id = '$TESTING_COMMIT_ID'
                AND
                    is_rollback = true
            ) > 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
}

@test "Successful deployment event, deployment stack is not finished, and rollback is needed" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    #TODO: Mock waiting executions and failed executions
}

@test "Failed deployment event and deployment stack is finished and rollback is needed" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    running_execution=$(jq -n \
    --arg execution_id "$execution_id" \
    --arg cfg_path "$testing_dir" \
    --arg commit_id "$commit_id" '
    {
        "execution_id": $execution_id,
        "cfg_path": $cfg_path,
        "commit_id": $commit_id
    }
    ')

    mock_cloudwatch_execution "$running_execution" "failed"

}

@test "Failed deployment event and deployment stack is not finished" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    running_execution=$(jq -n \
    --arg execution_id "$execution_id" \
    --arg cfg_path "$testing_dir" \
    --arg commit_id "$commit_id" '
    {
        "execution_id": $execution_id,
        "cfg_path": $cfg_path,
        "commit_id": $commit_id
    }
    ')

    mock_cloudwatch_execution "$running_execution" "failed"

}

@test "Successful rollback deployment event and dequeue next rollback stack" {
    running_execution=$(jq -n \
    --arg execution_id "$execution_id" \
    --arg is_rollback "true" '
    {
        "execution_id": $execution_id,
        "is_rollback": $cfg_path
    }
    ')

    mock_cloudwatch_execution "$running_execution" "success"

    #TODO: Mock waiting rollback deployment stack
}

@test "Successful rollback deployment event and dequeue next commit" {
    running_execution=$(jq -n \
    --arg execution_id "$execution_id" \
    --arg is_rollback "true" '
    {
        "execution_id": $execution_id,
        "is_rollback": $cfg_path
    }
    ')

    mock_cloudwatch_execution "$running_execution" "success"

    log "Creating test commit execution" "INFO"
    checkout_test_case_branch

    log "Modifying Terragrunt directories within test repo" "DEBUG"
    modify_tg_path --path "$abs_testing_dir"
    
    log "Committing modifications and adding commit to commit queue" "DEBUG"
    add_test_case_head_commit_to_queue
    
    log "Switching back to default branch" "DEBUG"
    git checkout "$(git remote show $(git remote) | sed -n '/HEAD branch/s/.*: //p')"

    run trigger_sf.sh
    assert_success

    log "Assert mock Cloudwatch event for step function execution has updated execution status" "INFO"
    log "$(psql -x "select * from executions where execution_id = '$execution_id';")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT 
                    COUNT(*)
                FROM 
                    executions
                WHERE
                    execution_id = '$execution_id' 
                AND
                    status = 'success'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success

    log "Assert mock commit for step function execution has been dequeued by having a running status" "INFO"
    log "$(psql -x "select * from executions where commit_id = '$TESTING_COMMIT_ID';")" "DEBUG"
    run psql -c """
    do \$\$
        BEGIN
            ASSERT (
                SELECT
                    COUNT(*)
                FROM
                    executions
                WHERE
                    commit_id = '$TESTING_COMMIT_ID' 
                AND
                    cfg_path = '$testing_dir' 
                AND
                    is_rollback = false 
                AND
                    status = 'running'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success
}
