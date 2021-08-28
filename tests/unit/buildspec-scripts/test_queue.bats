export script_logging_level="DEBUG"

setup_file() {
    load 'testing_utils.sh'

    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb
}

teardown_file() {
    load 'testing_utils.sh'

    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_metadb
}

setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../../../files/buildspec-scripts/queue.sh'
    load 'testing_utils.sh'

    # run_only_test "1"
}

teardown() {
    clear_metadb_tables
}

@test "script is runnable" {
    run queue.sh
}

@test "Add PR initial commit to queue" {
    export CODEBUILD_SOURCE_VERSION="pr/1"
    export CODEBUILD_WEBHOOK_BASE_REF="master"
    export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
    export CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"

    run add_commit_to_queue
    assert_success
}

# @test "Update PR's commit in queue" {
#     export CODEBUILD_SOURCE_VERSION="pr/1"
#     export CODEBUILD_WEBHOOK_BASE_REF="master"
#     export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
#     export CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"
#     sql="""
#     INSERT INTO commit_queue (
#         commit_id,
#         pr_id,
#         base_ref,
#         head_ref
#     )

#     SELECT
#         RANDOM_STRING(8),
#         RANDOM() * 2,
#         'master',
#         'feature-' || seq AS head_ref
#     FROM GENERATE_SERIES(1, 10) seq;
#     """

#     query "$sql"

#     run add_commit_to_queue
#     assert_success
# }

# @test "Commit already in queue" {
#     export CODEBUILD_SOURCE_VERSION="pr/1"
#     export CODEBUILD_WEBHOOK_BASE_REF="master"
#     export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
#     export CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"

#     run add_commit_to_queue
#     assert_failure
# }