export script_logging_level="DEBUG"
export MOCK_AWS_CMDS=true
# export KEEP_METADB_OPEN=true

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
    setup_test_case_branch

    run_only_test 2
}

teardown() {
    load 'test_helper/utils/load.bash'

    clear_metadb_tables
}

@test "Script is runnable" {
    run trigger_sf.sh
}

@test "Successful deployment event, dequeue deploy commit with no new providers" {

    modify_tg_path \
        --path "$TEST_CASE_REPO_DIR/directory_dependency/dev-account/us-west-2/env-one/bar"

    setup_test_case_commit
    
    export EVENTBRIDGE_EVENT=$(jq -n \
    --arg commit_id $(git rev-parse --verify HEAD) \
    --arg execution_id "$execution_id" '
        {
            "path": "test-path/",
            "execution_id": $execution_id,
            "deployment_type": "Deploy",
            "status": "SUCCESS",
            "commit_id": $commit_id
        } | tostring
    ')

    run trigger_sf.sh
    assert_success
}

@test "Successful deployment event, dequeue deploy commit with new providers" {
}

@test "Successful deployment event, deployment stack is finished and rollback is needed" {
}

@test "Successful deployment event, deployment stack is not finished, and rollback is needed" {
}

@test "Failed deployment event and deployment stack is finished" {
}

@test "Failed deployment event and deployment stack is not finished" {
}

@test "Successful rollback deployment event and dequeue next rollback stack" {
}

@test "Successful rollback deployment event and dequeue next commit" {
}
