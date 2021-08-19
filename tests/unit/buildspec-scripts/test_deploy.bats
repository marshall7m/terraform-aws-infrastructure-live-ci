export script_logging_level="DEBUG"
export MOCK_AWS_CMDS=true

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load 'testing_utils.sh'
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    src_path="$DIR/../../../files/buildspec-scripts"
    PATH="$src_path:$PATH"

    setup_tg_env
    TARGET_PATH="$TESTING_TMP_DIR"
    source shellmock

    skipIfNot "$BATS_TEST_DESCRIPTION"

    shellmock_clean

    #mocks all terragrunt commmands
    shellmock_expect terragrunt --status 0 --type partial

    run_only_test "2"
}

teardown() {
    teardown_tg_env

    if [ -z "$TEST_FUNCTION" ]; then
        shellmock_clean
    fi
}


@test "Script is runnable" {
    run deploy.sh
}

@test "Assert Deployment Plan Calls" {
    export DEPLOYMENT_TYPE="Deploy"
    export PLAN_COMMAND="plan"

    source mock_aws_cmds.sh
    run deploy.sh

    assert_output -p "FUNCNAME=update_pr_queue_with_new_providers"
}

@test "Assert Deployment Apply Calls" {
    export DEPLOYMENT_TYPE="Deploy"
    export DEPLOY_COMMAND="apply"
    
    run deploy.sh

    assert_output -p "FUNCNAME=update_pr_queue_with_new_resources"
}

@test "Assert Rollback Plan Calls" {
    export DEPLOYMENT_TYPE="Rollback"
    export PLAN_COMMAND="plan"
    
    run deploy.sh

    assert_output -p "FUNCNAME=update_pr_queue_with_destroy_targets_flags"
    assert_output -p "FUNCNAME=read_destroy_targets_flags"
}

@test "Assert Rollback Apply Calls" {
    export DEPLOYMENT_TYPE="Rollback"
    export DEPLOY_COMMAND="destroy"
    
    run deploy.sh

    assert_output -p "FUNCNAME=read_destroy_targets_flags"
}
