#!/bin/bash

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
source "$DIR/utils.sh"

add_commit_to_queue() {
    set -e
    
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    pr_id=$(echo $CODEBUILD_SOURCE_VERSION | cut -d "/" -f 2)
    log "Pull Request ID: ${pr_id}" "INFO"

    base_ref=$(echo $CODEBUILD_WEBHOOK_BASE_REF | cut -d "/" -f 3)
    log "Base Ref: ${base_ref}" "INFO"

    head_ref=$(echo $CODEBUILD_WEBHOOK_HEAD_REF | cut -d "/" -f 3)
    log "Head Ref: ${head_ref}" "INFO"

    log "Commit ID: ${CODEBUILD_RESOLVED_SOURCE_VERSION}" "INFO"

    sql="""
    INSERT INTO commit_queue(
        commit_id,
        pr_id,
        status,
        base_ref,
        head_ref,
        is_rollback
    )
    VALUES (
        '$CODEBUILD_RESOLVED_SOURCE_VERSION',
        '$pr_id',
        'Waiting',
        'master',
        '$head_ref',
        '0'
    )
    ON CONFLICT (commit_id, is_rollback) DO NOTHING;
    """
    log "Adding commit record to queue" "INFO"
    query "$sql"
    
    set +e
}

main() {
    add_commit_to_queue
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi