#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/test-helper/load.bash"
load "${BATS_TEST_DIRNAME}/../../../node_modules/bash-utils/load.bash"
load "${BATS_TEST_DIRNAME}/../../../node_modules/bats-utils/load.bash"

load "${BATS_TEST_DIRNAME}/../../../node_modules/bats-support/load.bash"
load "${BATS_TEST_DIRNAME}/../../../node_modules/bats-assert/load.bash"

load "${BATS_TEST_DIRNAME}/../../../node_modules/psql-utils/load.bash"

setup_file() {
    export script_logging_level="INFO"

    export BASE_REF=master
    export CODEBUILD_INITIATOR=rule/test
    export EVENTBRIDGE_FINISHED_RULE=rule/test

    source mock_aws_cmds.sh
    
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
    teardown_test_file_tmp_dir
}

setup() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    run_only_test 6

    bash "${BATS_TEST_DIRNAME}/test-helper/src/mock_tables.bash" \
        --table "account_dim" \
        --enable-defaults \
        --type-map "$(jq -n '{"account_deps": "TEXT[]"}')" \
        --items "$(jq -n '
            {
                "account_path": "directory_dependency/dev-account",
                "account_deps": []
            }
        ')"

    setup_test_case_repo
    cd "$TEST_CASE_REPO_DIR"
    setup_test_case_tf_state
}

teardown() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    clear_metadb_tables
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    run trigger_sf.sh
}

@test "Successful deployment event with new provider resources, dequeue deploy commit with no new providers" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
    
    cw_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$(jq -n '
            [
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/doo",
                    "create_provider_resource": true,
                    "apply_changes": false
                }
            ]
        ')" \
        --commit-item "$(jq -n ' {"status": "running"}')" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    finished_execution=$(echo "$cw_commit" | jq '
        {
            "cfg_path": .modify_items[0].cfg_path,
            "commit_id": .commit_id,
            "new_providers": []
        }
    ')

    mock_cloudwatch_execution "$finished_execution" "$success" 

    
    target_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$(jq -n '
            [
                {
                    "cfg_path": "directory_dependency/dev-account/global",
                    "create_provider_resource": false,
                    "apply_changes": false
                }
            ]
        ')" \
        --commit-item "$(jq -n '
            {
                "is_rollback": false,
                "status": "waiting"
            }
        ')" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    target_commit_id=$(echo "$target_commit" | jq -r '.commit_id')

    run trigger_sf.sh
    assert_success

    run assert_record_count --table "executions" --assert-count 1 \
        --execution-id "'$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'" \
        --status "'success'"
    assert_success

    log "Assert dequeued PR is running" "DEBUG"
    psql -c "SELECT * FROM pr_queue"
    run assert_record_count --table "pr_queue" --assert-count 1 \
        --pr-id "'$(echo "$target_commit" | jq -r '.pr_id')'" \
        --status "'running'"
    assert_success

    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$target_commit_id'" \
        --status "'running'"
    assert_success

    run assert_record_count --table "executions" --assert-count 1 \
        --commit-id "'$target_commit_id'" \
        --cfg-path "'$(echo "$target_commit" | jq -r '.modify_items[0].cfg_path')'" \
        --is-rollback "$(echo "$target_commit" | jq -r '.is_rollback')" \
        --status "'running'"
    assert_success
}

@test "Successful deployment event with no new provider resources, dequeue deploy commit with new providers" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
    log "Mocking cloudwatch commit" "INFO"

    cw_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --commit-item "$(jq -n ' {"status": "running"}')" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    log "Cloudwatch commit:" "DEBUG"
    log "$cw_commit" "DEBUG"

    cw_execution=$(echo "$cw_commit" | jq '
        {
            "cfg_path": "directory_dependency/dev-account/global",
            "pr_id": .pr_id,
            "commit_id": .commit_id,
            "status": .status,
            "is_rollback": false,
            "new_providers": []
        }
    ')

    cw_finished_status="success"

    log "Mocking cloudwatch execution" "INFO"
    mock_cloudwatch_execution "$cw_execution" "$cw_finished_status" 

    log "Creating mock commit and adding to queue" "INFO"
    target_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)" \
        --modify-items "$(jq -n '
            [
                {
                    "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/baz",
                    "create_provider_resource": true,
                    "apply_changes": false
                }
            ]
        ')" \
        --commit-item "$(jq -n '
            {
                "is_rollback": false,
                "status": "waiting"
            }
        ')"
    )

    run trigger_sf.sh
    assert_success

    target_commit_id=$(echo "$target_commit" | jq -r '.commit_id')

    run assert_record_count --table "executions" --assert-count 1 \
        --execution-id "'$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'" \
        --status "'success'"
    assert_success

    log "Assert dequeued PR is running" "DEBUG"
    psql -c "SELECT * FROM pr_queue"
    run assert_record_count --table "pr_queue" --assert-count 1 \
        --pr-id "'$(echo "$target_commit" | jq -r '.pr_id')'" \
        --status "'running'"
    assert_success

    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$target_commit_id'" \
        --status "'running'"
    assert_success

    run assert_record_count --table "executions" --assert-count 1 \
        --commit-id "'$target_commit_id'" \
        --cfg-path "'$(echo "$target_commit" | jq -r '.modify_items[0].cfg_path')'" \
        --new-providers "ARRAY['$(echo "$target_commit" | jq -r '.modify_items[0].address')']" \
        --status "'running'"
    assert_success
}


@test "Successful deployment event, commit deployment stack is finished and contains new providers and rollback is needed" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
    log "Mocking cloudwatch commit" "INFO"

    target_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --modify-items "$(jq -n '
        [
            {
                "apply_changes": true,
                "create_provider_resource": true,
                "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/baz",
            }
        ]')" \
        --commit-item "$(jq -n ' {"status": "running"}')" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    log "Target commit:" "DEBUG"
    log "$target_commit" "DEBUG"

    cw_execution=$(echo "$target_commit" | jq '
        {
            "cfg_path": "directory_dependency/dev-account/global",
            "pr_id": .pr_id,
            "commit_id": .commit_id,
            "status": .status,
            "is_rollback": false,
            "new_providers": []
        }
    ')

    cw_finished_status="success"

    log "Mocking cloudwatch execution" "INFO"
    mock_cloudwatch_execution "$cw_execution" "$cw_finished_status" 

    log "Mocking failed execution" "INFO"

    type_map=$(jq -n '
    {
        "new_providers": "TEXT[]", 
        "new_resources": "TEXT[]"
    }
    ')
    
    failed_execution=$(echo "$target_commit" | jq '
        {
            "cfg_path": .modify_items[0].cfg_path,
            "is_rollback": false,
            "status": "failed",
            "pr_id": .pr_id,
            "commit_id": .commit_id,
            "new_providers": [.modify_items[0].address],
            "new_resources": [.modify_items[0].resource_spec]
        }
    ')
    
    bash "${BATS_TEST_DIRNAME}/test-helper/src/mock_tables.bash" \
        --table "executions" \
        --items "$failed_execution" \
        --type-map "$type_map" \
        --enable-defaults
    
    log "Adding rollback commit to commit queue" "INFO"
    bash "${BATS_TEST_DIRNAME}/../../../node_modules/psql-utils/src/jq_to_psql_records.bash" \
        --table "commit_queue" \
        --jq-input "$(echo "$target_commit" | jq '
            {
                "commit_id": .commit_id,
                "is_rollback": true,
                "pr_id": .pr_id,
                "status": "waiting"
            }
        ')"
    psql -c """
    SELECT * FROM commit_queue
    """
    
    run trigger_sf.sh
    assert_success

    target_commit_id=$(echo "$target_commit" | jq -r '.commit_id')
    psql -x -c "select * from executions where execution_id = '$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'"
    log "Assert mock Cloudwatch event status was updated" "INFO"
    run assert_record_count --table "executions" --assert-count 1 \
        --execution-id "'$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'" \
        --status "'success'"
    assert_success

    log "Assert mock commit deploy waiting executions are aborted" "INFO"
    run assert_record_count --table "executions" --assert-count 0 \
        --commit-id "'$target_commit_id'" \
        --status "'waiting'" \
        --is-rollback false
    assert_success

    log "Assert mock commit deployment is failed" "INFO"
    psql -c "SELECT * FROM commit_queue"
    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$target_commit_id'" \
        --status "'failed'" \
        --is-rollback false
    assert_success

    log "Assert mock commit rollback is running" "INFO"
    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$target_commit_id'" \
        --status "'running'" \
        --is-rollback true
    assert_success

    log "Assert mock commit rollback executions are created" "INFO"
    run assert_record_count --table "executions" --assert-count 1 \
        --commit-id "'$target_commit_id'" \
        --cfg-path "'$(echo "$target_commit" | jq -r '.modify_items[0].cfg_path')'" \
        --new-providers "ARRAY['$(echo "$target_commit" | jq -r '.modify_items[0].address')']" \
        --status "'running'" \
        --is-rollback true
    assert_success
}

@test "Failed deployment event, commit deployment stack is finished, another commit from same PR is in queue" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    log "Mocking cloudwatch commit" "INFO"

    cw_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --commit-item "$(jq -n ' {"status": "running"}')" \
        --modify-items "$(jq -n '
        [
            {
                "apply_changes": true,
                "create_provider_resource": true,
                "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/baz",
            }
        ]')" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    log "Cloudwatch commit:" "DEBUG"
    log "$cw_commit" "DEBUG"

    cw_execution=$(echo "$cw_commit" | jq '
        {
            "cfg_path": .modify_items[0].cfg_path,
            "pr_id": .pr_id,
            "commit_id": .commit_id,
            "status": .status,
            "is_rollback": false,
            "is_base_rollback": false,
            "new_providers": [.modify_items[0].address],
            "new_resources": [.modify_items[0].resource_spec]
        }
    ')

    cw_finished_status="failed"

    log "Mocking cloudwatch execution" "INFO"
    mock_cloudwatch_execution "$cw_execution" "$cw_finished_status" 

    log "Mocking commit with the same PR ID as CW event" "DEBUG"
    type_map=$(jq -n '
    {
        "new_providers": "TEXT[]", 
        "new_resources": "TEXT[]"
    }
    ')
    
    target_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --commit-item "$(echo "$cw_commit" | jq '{
            "pr_id": .pr_id,
            "status": "waiting"
        }')" \
        --head-ref "test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"
    )

    run trigger_sf.sh
    assert_success
    
    log "Assert mock Cloudwatch event status was updated" "INFO"
    psql -x -c "select * from executions where execution_id = '$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'"
    run assert_record_count --table "executions" --assert-count 1 \
        --execution-id "'$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'" \
        --status "'$cw_finished_status'"
    assert_success
    
    log "Assert mock commit deployment status is set to failed" "INFO"
    psql -x -c "select * from commit_queue where commit_id = '$(echo "$cw_commit" | jq -r '.commit_id')'"
    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$(echo "$cw_commit" | jq -r '.commit_id')'" \
        --status "'failed'" \
        --is-rollback false
    assert_success

    log "Assert rollback commit is running" "INFO"
    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$(echo "$cw_commit" | jq -r '.commit_id')'" \
        --status "'running'" \
        --is-rollback true
    assert_success

    log "Assert next deploy commit is waiting" "INFO"
    psql -x -c "select * from commit_queue where commit_id = '$(echo "$target_commit" | jq -r '.commit_id')'"
    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$(echo "$target_commit" | jq -r '.commit_id')'" \
        --status "'waiting'" \
        --is-rollback false
    assert_success

    log "Assert cloudwatch commit rollback executions are created" "INFO"
    psql -x -c "select * from executions where commit_id = '$(echo "$cw_commit" | jq -r '.commit_id')'"
    run assert_record_count --table "executions" --assert-count 1 \
        --commit-id "'$(echo "$cw_commit" | jq -r '.commit_id')'" \
        --cfg-path "'$(echo "$cw_commit" | jq -r '.modify_items[0].cfg_path')'" \
        --new-providers "ARRAY['$(echo "$cw_commit" | jq -r '.modify_items[0].address')']" \
        --status "'running'" \
        --is-rollback true
    assert_success
}


@test "Successful rollback deployment event and dequeue base rollback execution" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    log "Mocking cloudwatch commit" "INFO"

    cw_head_ref="test-case-$BATS_TEST_NUMBER-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)"

    cw_commit=$(bash "$BATS_TEST_DIRNAME/test-helper/src/mock_commit.bash" \
        --abs-repo-dir "$TEST_CASE_REPO_DIR" \
        --commit-item "$(jq -n ' {"status": "running"}')" \
        --modify-items "$(jq -n '
        [
            {
                "apply_changes": true,
                "create_provider_resource": true,
                "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/baz",
            }
        ]')" \
        --head-ref $cw_head_ref
    )

    log "Cloudwatch commit:" "DEBUG"
    log "$cw_commit" "DEBUG"

    cw_execution=$(echo "$cw_commit" | jq '
        {
            "cfg_path": .modify_items[0].cfg_path,
            "pr_id": .pr_id,
            "commit_id": .commit_id,
            "status": .status,
            "is_rollback": true,
            "is_base_rollback": false,
            "new_providers": [.modify_items[0].address],
            "new_resources": [.modify_items[0].resource_spec]
        }
    ')

    cw_finished_status="success"

    log "Mocking cloudwatch execution" "INFO"
    mock_cloudwatch_execution "$cw_execution" "$cw_finished_status" 
    
    log "Mocking base rollback commit with the same PR ID as CW event" "DEBUG"

    base_commit_id=$( cd "$TEST_CASE_REPO_DIR" && git rev-parse --verify $BASE_REF )
    bash "${BATS_TEST_DIRNAME}/../../../node_modules/psql-utils/src/jq_to_psql_records.bash" \
        --table "commit_queue" \
        --jq-input "$(echo "$cw_commit" | jq --arg commit_id "$base_commit_id" '{
            "pr_id": .pr_id,
            "commit_id": $commit_id,
            "status": "waiting",
            "is_rollback": true,
            "is_base_rollback": true
        }')"

    run trigger_sf.sh
    assert_success
    assert_output "zozoz"

    log "Assert mock Cloudwatch event status was updated" "INFO"
    psql -x -c "select * from executions where execution_id = '$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'"
    run assert_record_count --table "executions" --assert-count 1 \
        --execution-id "'$(echo "$EVENTBRIDGE_EVENT" | jq -r '.execution_id')'" \
        --status "'$cw_finished_status'"
    assert_success
    
    log "Assert mock rollback commit status was updated" "INFO"
    psql -x -c "select * from commit_queue where commit_id = '$(echo "$cw_commit" | jq -r '.commit_id')'"
    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$(echo "$cw_commit" | jq -r '.commit_id')'" \
        --status "'success'" \
        --is-rollback true \
        --is-base-rollback false
    assert_success

    log "Assert base rollback commit is running" "INFO"
    run assert_record_count --table "commit_queue" --assert-count 1 \
        --commit-id "'$base_commit_id'" \
        --status "'running'" \
        --is-rollback true \
        --is-base-rollback true
    assert_success

    log "Assert cloudwatch commit base rollback executions are created" "INFO"
    psql -x -c "select * from executions where commit_id = '$(echo "$base_commit_id" | jq -r '.commit_id')'"
    run assert_record_count --table "executions" --assert-count 1 \
        --commit-id "'$base_commit_id'" \
        --cfg-path "'$(echo "$cw_commit" | jq -r '.modify_items[0].cfg_path')'" \
        --new-providers "ARRAY[]" \
        --status "'running'" \
        --is-rollback true \
        --is-base-rollback true
    assert_success
}

@test "Successful base rollback deployment event and dequeue next commit from same PR" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
}

