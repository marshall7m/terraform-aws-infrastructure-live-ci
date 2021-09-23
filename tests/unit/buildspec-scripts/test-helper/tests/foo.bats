@test "foo" {
    export script_logging_level="DEBUG"
    export KEEP_METADB_OPEN=true
    export METADB_TYPE=local

    load 'common_setup.bash'

    _common_setup
    
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb

    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"
    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
    setup_test_file_tf_state "directory_dependency/dev-account"
}