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
        commit_status,
        base_ref,
        head_ref,
        execution_type
    )
    VALUES (
        '$CODEBUILD_RESOLVED_SOURCE_VERSION',
        '$pr_id',
        'Waiting',
        'master',
        '$base_ref',
        'deploy'
    );
    """
    log "Running Query" "INFO"
    query "$sql"
}

main() {
    set -e

    add_commit_to_queue

    commit_queue=$(get_commit_queue)
    log "Updated Commit Queue:" "DEBUG"
    log "$commit_queue" "DEBUG"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi