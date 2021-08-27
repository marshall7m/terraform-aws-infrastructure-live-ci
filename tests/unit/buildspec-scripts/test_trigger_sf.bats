
setup() {
    export MOCK_TG_CMDS=true
    export MOCK_GIT_CMDS=true
    export MOCK_AWS_CMDS=true
    export script_logging_level="DEBUG"

    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load 'test_helper/bats-mock/stub'
    load 'testing_utils.sh'
    load '../../../files/buildspec-scripts/trigger_sf.sh'

    # setup_tg_env
    run_only_test "2"
}

teardown() {
    teardown_tg_env
}

@test "Script is runnable" {
    run trigger_sf.sh
}

@test "Successful deployment event without new provider resources" {
    get_build_artifacts() {
        executions=$(jq -n '[
            {
                "path": "test-path/",
                "execution_id": "test-id",
                "deployment_type": "Deploy",
                "status": "RUNNING",
                "new_providers"
            }
        ]')

        commit_queue=$(jq -n '
        [
            {
                "commit_id": "commit-3",
                "pr_id": 1,
                "status": "Waiting",
                "base_ref": "master",
                "head_ref": "feature-1",
                "type": "Deploy"
            },
            {
                "commit_id": "commit-2",
                "pr_id": 1,
                "status": "Waiting",
                "base_ref": "master",
                "head_ref": "feature-1",
                "type": "Deploy"
            },
            {
                "commit_id": "commit-1",
                "pr_id": 2,
                "status": "Success",
                "base_ref": "master",
                "head_ref": "feature-2",
                "type": "Deploy"
            }
        ]')

        account_dim=$(jq -n '[
            {
                "account_name": "test-account",
                "account_path": "test-path",
                "min_approval_count": 3,
                "min_rejection_count": 3,
                "voters": ["test-voter"]
            }
        ]')
    }

    export -f get_build_artifacts
    
    export EVENTBRIDGE_EVENT=$(jq -n \
    --arg commit_id $(git rev-parse --verify HEAD) '
        {
            "path": "test-path/",
            "execution_id": "test-id",
            "deployment_type": "Deploy",
            "status": "SUCCESS",
            "commit_id": $commit_id
        } | tostring
    ')

    run main
    assert_success
}