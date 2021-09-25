export script_logging_level="DEBUG"
# export KEEP_METADB_OPEN=true

setup_file() {
    load 'test-helper/common-setup'
    _common_setup

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


@test "Script is runnable" {
    run queue.sh
}


@test "Add new PR initial commit to queue" {
    export CODEBUILD_SOURCE_VERSION="pr/1"
    export CODEBUILD_WEBHOOK_BASE_REF="master"
    export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
    export CODEBUILD_RESOLVED_SOURCE_VERSION="commit-id-1"

    run queue.sh
    assert_success

    assert_sql="""
    do \$\$
        BEGIN
            ASSERT (
                SELECT COUNT(*)
                FROM commit_queue
                WHERE
                    commit_id = '$CODEBUILD_RESOLVED_SOURCE_VERSION'
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """

    psql -c "$assert_sql"
    assert_success
}

@test "Update PR's commit in queue" {
    export CODEBUILD_SOURCE_VERSION="pr/1"
    export CODEBUILD_WEBHOOK_BASE_REF="master"
    export CODEBUILD_WEBHOOK_HEAD_REF="feature-1"
    export CODEBUILD_RESOLVED_SOURCE_VERSION="commit-id-1"
    sql="""
    INSERT INTO commit_queue (
        commit_id,
        pr_id,
        status,
        base_ref,
        head_ref,
        is_rollback
    )

    SELECT
        substr(md5(random()::text), 0, 25),
        RANDOM() * 2,
        'Waiting',
        'master',
        'feature-' || seq,
        false
    FROM GENERATE_SERIES(1, 10) seq;
    """

    psql -c "$sql"

    run queue.sh
    assert_success

    assert_sql="""
    do \$\$
        BEGIN
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
            ) = 1;
        END;
    \$\$ LANGUAGE plpgsql;
    """

    results=$(psql -x "SELECT * FROM commit_queue WHERE commit_id = 'CODEBUILD_RESOLVED_SOURCE_VERSION';")
    log "Commit records:" "DEBUG"
    log "$results" "DEBUG"

    run psql -c "$assert_sql"
    assert_success
}