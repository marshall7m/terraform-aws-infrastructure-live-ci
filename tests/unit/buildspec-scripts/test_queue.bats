export script_logging_level="DEBUG"
# export KEEP_METADB_OPEN=true

setup_file() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
    load '../../../files/buildspec-scripts/queue.sh'
    load 'testing_utils/utils.sh'

    log "FUNCNAME=$FUNCNAME" "DEBUG"
    setup_metadb
}

teardown_file() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    teardown_metadb
}

setup() {
    run_only_test "1"
}

teardown() {
    clear_metadb_tables
}

@test "script is runnable" {
    run queue.sh
}

@test "Add new PR initial commit to queue" {
    export CODEBUILD_SOURCE_VERSION="pr/1"
    export CODEBUILD_WEBHOOK_BASE_REF="master"
    export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
    export CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"

    run add_commit_to_queue
    assert_success

    assert_sql="""
    do \$\$
        begin
            ASSERT (
                SELECT COUNT(*)
                FROM commit_queue
                WHERE
                    commit_id = '$CODEBUILD_RESOLVED_SOURCE_VERSION' 
            ) == 1
        end;
    \$\$
            ;
    """
    query "$assert_sql"
    [ $? -eq 0 ]
}

@test "Update PR's commit in queue" {
    export CODEBUILD_SOURCE_VERSION="pr/1"
    export CODEBUILD_WEBHOOK_BASE_REF="master"
    export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
    export CODEBUILD_RESOLVED_SOURCE_VERSION="test-commit-id"
    sql="""
    INSERT INTO commit_queue (
        commit_id,
        pr_id,
        base_ref,
        head_ref
    )

    SELECT
        substr(md5(random()::text), 0, 25),
        RANDOM() * 2,
        'master',
        'feature-' || seq AS head_ref
    FROM GENERATE_SERIES(1, 10) seq;
    """

    query "$sql"

    run add_commit_to_queue
    assert_success

    assert_sql="""
    do \$\$
        begin
            ASSERT (
                SELECT COUNT(*)
                FROM commit_queue 
                WHERE
                    commit_id = '$CODEBUILD_RESOLVED_SOURCE_VERSION'
                AND
                    pr_id = 1
                AND
                    base_ref = '$CODEBUILD_WEBHOOK_BASE_REF'
                AND
                    head_ref = '$CODEBUILD_WEBHOOK_HEAD_REF'
            ) == 1;
        end;
    \$\$
    """
    query "$assert_sql"
    [ $? -eq 0 ]
}