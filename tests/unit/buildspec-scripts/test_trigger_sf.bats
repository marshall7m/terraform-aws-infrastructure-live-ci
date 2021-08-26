
setup() {
    export MOCK_TG_CMDS=true
    export MOCK_GIT_CMDS=true
    export MOCK_AWS_CMDS=true
    export script_logging_level="DEBUG"

    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load 'testing_utils.sh'

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    src_path="$DIR/../../../files/buildspec-scripts"
    PATH="$src_path:$PATH"
    
    setup_tg_env

    source shellmock

    skipIfNot "$BATS_TEST_DESCRIPTION"

    shellmock_clean

    run_only_test "1"
}

teardown() {
    teardown_tg_env

    if [ -z "$TEST_FUNCTION" ]; then
        shellmock_clean
    fi
}

@test "Script is runnable" {
    run trigger_sf.sh
}


@test "Successful Deployment Event" {
    source "./mock_aws_cmds.sh"
    setup_existing_provider
    setup_new_provider
    setup_apply_new_provider
    
    export EVENTBRIDGE_EVENT=$(jq -n \
    --arg commit_id $(git rev-parse --verify HEAD) '
        {
            "path": "test-path/",
            "execution_id": "test-id",
            "deployment_type": "Deploy",
            "status": "SUCCESS",
            "commit_id": $commit_id
        }
    ')

    executions=$(jq -n '[
        {
            "path": "test-path/",
            "execution_id": "test-id",
            "deployment_type": "Deploy",
            "status": "RUNNING"
            "new_providers"
        }
    ]')
    expected=$(jq -n \
        '')

    run trigger_sf.sh "$executions" "$TESTING_TMP_DIR"
    assert_output -p "$expected"
}