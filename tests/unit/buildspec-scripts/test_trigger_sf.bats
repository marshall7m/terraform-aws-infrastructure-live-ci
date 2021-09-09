export script_logging_level="DEBUG"
export MOCK_AWS_CMDS=true
# export KEEP_METADB_OPEN=true
export METADB_TYPE=local

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup_file() {
    load 'test_helper/utils/load.bash'

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
    load 'test_helper/utils/load.bash'
    
    setup_test_case_repo

    run_only_test 1
}

teardown() {
    load 'test_helper/utils/load.bash'

    clear_metadb_tables
    drop_mock_temp_tables
}

@test "Script is runnable" {
    run trigger_sf.sh
}

# @test "setup mock tables" {
#     account_stack=$(jq -n '
#     {
#         "directory_dependency/dev-account": ["directory_dependency/security-account"]
#     }
#     ')

#     run setup_mock_finished_status_tables \
#         --based-on-tg-dir "$TEST_CASE_REPO_DIR/directory_dependency" \
#         --account-stack "$account_stack"
    
#     assert_success
# }

@test "Successful deployment event, dequeue deploy commit with no new providers" {
    export CODEBUILD_INITIATOR=rule/test
    export EVENTBRIDGE_FINISHED_RULE=rule/test

    log "Applying default branch Terragrunt configurations" "INFO"
    testing_dir="$TEST_CASE_REPO_DIR/directory_dependency/dev-account/us-west-2/env-one/bar"
    log "Terragrunt directory: $testing_dir" "DEBUG"
	terragrunt apply --terragrunt-working-dir "$testing_dir" -auto-approve > /dev/null || exit 1
    
    execution_id=run-0000001
    commit_id=$(git log --pretty=format:'%H' -n 1)

    before_execution=$(jq -n \
    --arg execution_id "$execution_id" \
    --arg commit_id "$commit_id" '
        {
            "execution_id": $execution_id,
            "is_rollback": false,
            "pr_id": "1",
            "commit_id": $commit_id,
            "cfg_path": "directory_dependency/dev-account/us-west-2/env-one/foo",
            "cfg_deps": [],            
            "status": "running",
            "plan_command": "terragrunt plan --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/foo",
            "deploy_command": "terragrunt apply --terragrunt-working-dir directory_dependency/dev-account/us-west-2/env-one/foo",
            "new_providers": [],
            "new_resources": [],
            "account_name": "dev",
            "account_deps": [],
            "account_path": "directory_dependency/dev-account",
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

    account_stack=$(jq -n '
    {
        "directory_dependency/dev-account": ["directory_dependency/security-account"]
    }
    ')

    setup_mock_finished_status_tables \
        --based-on-tg-dir "$TEST_CASE_REPO_DIR/directory_dependency" \
        --account-stack "$account_stack"

    checkout_test_case_branch

    log "Modifying Terragrunt directories within test repo" "DEBUG"
    modify_tg_path --path "$testing_dir"
    
    log "Committing modifications and adding commit to commit queue" "DEBUG"
    add_test_case_head_commit_to_queue
    
    log "Switching back to default branch" "DEBUG"
    git remote show $(git remote) | sed -n '/HEAD branch/s/.*: //p'

    run trigger_sf.sh
    assert_success

    # run query """
    # do \$\$
    #     BEGIN
    #         ASSERT (
    #             SELECT 
    #                 COUNT(*)
    #             FROM 
    #                 executions
    #             WHERE
    #                 execution_id = '$execution_id' AND
    #                 status = 'success'
    #         ) = 1;
    #     END;
    # \$\$ LANGUAGE plpgsql;
    # """
    # assert_success

    # run query """
    # do \$\$
    #     BEGIN
    #         ASSERT (
    #             SELECT
    #                 COUNT(*)
    #             FROM
    #                 executions
    #             WHERE
    #                 commit_id = '$TESTING_COMMIT_ID' AND
    #                 cfg_path = '$("$testing_dir" | tr -d '"')' AND
    #                 is_rollback = false AND
    #                 status = 'running'
    #         ) = 1;
    #     END;
    # \$\$ LANGUAGE plpgsql;
    # """
    # assert_success
}

# @test "Successful deployment event, dequeue deploy commit with new providers" {
# }

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
