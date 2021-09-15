load '../../bats-support/load'
load '../../bats-assert/load'
export script_logging_level="DEBUG"

setup_file() {
    load '../load.bash'
    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"
    
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_test_file_tmp_dir
}

setup() {
    load '../load.bash'
    
    setup_test_case_repo
}

teardown() {
    load '../load.bash'
    teardown_test_case_tmp_dir
}

@test "Script is runnable" {
    run mock_commit.bash
}

@test "setup terragrunt mock config" {
    log "TEST CASE: $BATS_TEST_NUMBER" "INFO"

    testing_dir="directory_dependency/dev-account/global"
    abs_testing_dir="$TEST_CASE_REPO_DIR/$testing_dir"

    res=$(modify_tg_path --path "$abs_testing_dir" --new-provider-resource)
    
    log "Assert provider results" "INFO"
    run echo "$res"
    assert_output --regexp '.+'

    log "Assert resource results" "INFO"
    run echo "$res" | jq 'map(.resource)[0]'
    assert_output --regexp '.+\..+'
}
