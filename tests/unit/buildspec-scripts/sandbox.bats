#!/usr/bin/env bats

@test "setup" {
    export script_logging_level="DEBUG"

    export BASE_REF=master
    export CODEBUILD_INITIATOR=rule/test
    export EVENTBRIDGE_FINISHED_RULE=rule/test

    log "FUNCNAME=$FUNCNAME" "DEBUG"

    source mock_aws_cmds.sh

    load 'test-helper/load.bash'
    
    load 'common_setup.bash'
    _common_setup
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb

    export TESTING_LOCAL_PARENT_TF_STATE_DIR="$BATS_TEST_TMPDIR/test-repo-tf-state"
    setup_test_file_repo "https://github.com/marshall7m/infrastructure-live-testing-template.git"
    setup_test_file_tf_state "directory_dependency/dev-account"
}