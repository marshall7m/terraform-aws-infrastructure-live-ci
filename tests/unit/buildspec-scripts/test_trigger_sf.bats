export script_logging_level="DEBUG"
export MOCK_AWS_CMDS=true
export KEEP_METADB_OPEN=true
export METADB_TYPE=local

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup_file() {
    export BASE_REF=master

    load 'test_helper/utils/load.bash'

    _common_setup
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb

    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_metadb
    teardown_test_file_tmp_dir
}

setup() {
    load 'test_helper/utils/load.bash'
    
    setup_test_case_repo

    run_only_test 2

    #TODO: not neccessary for scope of tests?
    # setup_mock_finished_status_tables \
    #     --based-on-tg-dir "$TEST_CASE_REPO_DIR/directory_dependency" \
    #     --account-stack "$account_stack"
}

teardown() {
    load 'test_helper/utils/load.bash'
    clear_metadb_tables
    drop_mock_temp_tables
    drop_temp_tables
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    run trigger_sf.sh
}

@test "setup modify path" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    export CODEBUILD_INITIATOR=rule/test
    export EVENTBRIDGE_FINISHED_RULE=rule/test
    #creates persistent local tf state for test case repo even when test repo commits are checked out (see test repo's parent terragrunt file generate backend block)
    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"

    execution_id="run-0000001"
    log "Applying default branch Terragrunt configurations" "INFO"
    testing_dir="directory_dependency/dev-account/global"
    abs_testing_dir="$TEST_CASE_REPO_DIR/$testing_dir"

    log "Modifying Terragrunt directories within test repo" "DEBUG"
    run modify_tg_path --path "$abs_testing_dir" --new-provider-resource
    mock_provider=$(echo "$res" | jq 'keys[0]')
    mock_resource=$(echo "$res" | jq 'map(.resource)[0]' | tr -d '"')
    echo "mock provider: $mock_provider"
    echo "mock resource: $mock_resource"
    assert_failure
    
}

@test "Successful deployment event with new provider resources, dequeue deploy commit with no new providers" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    export CODEBUILD_INITIATOR=rule/test
    export EVENTBRIDGE_FINISHED_RULE=rule/test
    #creates persistent local tf state for test case repo even when test repo commits are checked out (see test repo's parent terragrunt file generate backend block)
    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"

    execution_id="run-0000001"
    log "Applying default branch Terragrunt configurations" "INFO"
    testing_dir="directory_dependency/dev-account/global"
    abs_testing_dir="$TEST_CASE_REPO_DIR/$testing_dir"

    log "Modifying Terragrunt directories within test repo" "DEBUG"
    res=$(modify_tg_path --path "$abs_testing_dir" --new-provider-resource)
    mock_provider=$(echo "$res" | jq 'keys[0]')
    mock_resource=$(echo "$res" | jq 'map(.resource)[0]' | tr -d '"')
    
    log "Terragrunt directory: $abs_testing_dir" "DEBUG"
	terragrunt apply --terragrunt-working-dir "$abs_testing_dir" -auto-approve > /dev/null || exit 1
    
    before_execution=$(jq -n \
    --arg execution_id "$execution_id" \
    --arg pr_id 1 \
    --arg base_ref "$BASE_REF" \
    --arg base_commit_id "$( git log --pretty=format:'%H' -n 1 --skip 1 )" \
    --arg commit_id "$( git log --pretty=format:'%H' -n 1 )" \
    --arg new_providers "$mock_provider" '
        {
            "execution_id": $execution_id,
            "is_rollback": false,
            "pr_id": $pr_id,
            "commit_id": $commit_id,
            "base_source_version": "refs/heads/\($base_ref)^{\($base_commit_id)}",
            "head_source_version": "refs/pull/\($pr_id)/head^{\($commit_id)}",
            "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/foo",
            "cfg_deps": [],            
            "status": "running",
            "plan_command": "terragrunt plan --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/foo",
            "deploy_command": "terragrunt apply --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/foo",
            "new_providers": $new_providers,
            "new_resources": [],
            "account_name": "dev",
            "account_path": "directory_dependency/dev-account",
            "account_deps": [],
            "voters": ["voter-001"],
            "approval_count": 1,
            "min_approval_count": 1,
            "rejection_count": 1,
            "min_rejection_count": 1    
        }
    ')

    jq_to_psql_records "$before_execution" "executions"

    log "Using default branch head commit as previous Step Function deployment" "INFO"
    export EVENTBRIDGE_EVENT=$( echo "$before_execution" | jq '.status = "success" | tostring')

    log "Creating mock account_dim" "INFO"
    account_stack=$(jq -n '
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

    jq_to_psql_records "$account_stack" "account_dim"

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
    run query """
    do \$\$
        BEGIN
            ASSERT (
                SELECT 
                    COUNT(*)
                FROM 
                    executions
                WHERE
                    execution_id = '$execution_id' 
                    new_resources = ARRAY['$mock_resource']
                AND
                    status = 'success'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """
    assert_success

    log "Assert mock commit for step function execution has been dequeued by having a running status" "INFO"
    run query """
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

@test "Successful deployment event with no new provider resources, dequeue deploy commit with new providers" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    export CODEBUILD_INITIATOR=rule/test
    export EVENTBRIDGE_FINISHED_RULE=rule/test
    #creates persistent local tf state for test case repo even when test repo commits are checked out (see test repo's parent terragrunt file generate backend block)
    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"

    execution_id="run-0000001"
    log "Applying default branch Terragrunt configurations" "INFO"
    testing_dir="directory_dependency/dev-account/global"
    abs_testing_dir="$TEST_CASE_REPO_DIR/$testing_dir"
    log "Terragrunt directory: $abs_testing_dir" "DEBUG"
	terragrunt apply --terragrunt-working-dir "$abs_testing_dir" -auto-approve > /dev/null || exit 1
    
    before_execution=$(jq -n \
    --arg execution_id "$execution_id" \
    --arg pr_id 1 \
    --arg base_ref "$BASE_REF" \
    --arg base_commit_id "$( git log --pretty=format:'%H' -n 1 --skip 1 )" \
    --arg commit_id "$( git log --pretty=format:'%H' -n 1 )" '
        {
            "execution_id": $execution_id,
            "is_rollback": false,
            "pr_id": $pr_id,
            "commit_id": $commit_id,
            "base_source_version": "refs/heads/\($base_ref)^{\($base_commit_id)}",
            "head_source_version": "refs/pull/\($pr_id)/head^{\($commit_id)}",
            "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/foo",
            "cfg_deps": [],            
            "status": "running",
            "plan_command": "terragrunt plan --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/foo",
            "deploy_command": "terragrunt apply --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/foo",
            "new_providers": [],
            "new_resources": [],
            "account_name": "dev",
            "account_path": "directory_dependency/dev-account",
            "account_deps": [],
            "voters": ["voter-001"],
            "approval_count": 1,
            "min_approval_count": 1,
            "rejection_count": 1,
            "min_rejection_count": 1    
        }
    ')

    jq_to_psql_records "$before_execution" "executions"

    log "Using default branch head commit as previous Step Function deployment" "INFO"
    export EVENTBRIDGE_EVENT=$( echo "$before_execution" | jq '.status = "success" | tostring')

    log "Creating mock account_dim" "INFO"
    account_stack=$(jq -n '
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

    jq_to_psql_records "$account_stack" "account_dim"

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
    run query """
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
    run query """
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


# @test "Successful deployment event, deployment stack is finished and rollback is needed" {
# }

# @test "Successful deployment event, deployment stack is not finished, and rollback is needed" {
# }

# @test "Failed deployment event and deployment stack is finished" {
# }

# @test "Failed deployment event and deployment stack is not finished" {
# }

# @test "Successful rollback deployment event and dequeue next rollback stack" {
# }

# @test "Successful rollback deployment event and dequeue next commit" {
# }
