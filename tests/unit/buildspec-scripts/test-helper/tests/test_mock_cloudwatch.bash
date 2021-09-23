load '../../bats-support/load'
load '../../bats-assert/load'
export script_logging_level="DEBUG"
set -a
load "../load.bash"
set +a

setup_file() {
    src_path="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../src" >/dev/null 2>&1 && pwd )"
    PATH="$src_path:$PATH"
    chmod u+x "$src_path"

    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"
    
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_test_file_tmp_dir
}

setup() {
    load './load.bash'
    
    setup_test_case_repo

    run_only_test 2
}

teardown() {
    load './load.bash'
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    run mock_cloudwatch_execution
}

@test "setup terragrunt mock config" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"
    
    testing_dir="directory_dependency/dev-account/global"
    abs_testing_dir="$TEST_CASE_REPO_DIR/$testing_dir"

    run mock_cloudwatch_execution \
        --cfg-path "$testing_dir" \
        --approval-count 1
    assert_output -p '"approval_count": 1'
    assert_output -p "\"cfg_path\": \"$testing_dir\""
}
