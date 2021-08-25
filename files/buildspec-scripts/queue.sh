#!/bin/bash

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
source "$DIR/utils.sh"

create_commit_item() {
    set -e

    check_for_env_var "$CODEBUILD_SOURCE_VERSION"
    check_for_env_var "$CODEBUILD_WEBHOOK_BASE_REF"
    check_for_env_var "$CODEBUILD_RESOLVED_SOURCE_VERSION"
    
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    pr_id=$(echo $CODEBUILD_SOURCE_VERSION | cut -d "/" -f 2)
    log "Pull Request ID: ${pr_id}" "INFO"

    base_ref=$(echo $CODEBUILD_WEBHOOK_BASE_REF | cut -d "/" -f 3)
    log "Base Ref: ${base_ref}""INFO"

    head_ref=$(echo $CODEBUILD_WEBHOOK_HEAD_REF | cut -d "/" -f 3)
    log "Head Ref: ${head_ref}" "INFO"

    log "Commit ID: ${CODEBUILD_RESOLVED_SOURCE_VERSION}" "INFO"


    echo "$(jq -n '
    --arg pr_id $pr_id \
    --arg commit_id $CODEBUILD_RESOLVED_SOURCE_VERSION \
    --arg base_ref $base_ref \
    --arg head_ref $head_ref
        {
            "pr_id": $pr_id,
            "commit_id": $commit_id,
            "base_ref": $base_ref,
            "head_ref": $head_ref
        }
    ')"
}

add_commit_to_queue() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local queue=$1
    local item=$2
    log "Item:" "DEBUG"
    log "$item" "DEBUG"

    echo "$(echo $queue | jq \
    --arg item $item '
    ($item | tojson) as $item
    | . + [$item]
    ')"
}

main() {
    set -e

    check_for_env_var "$ARTIFACT_BUCKET_NAME"
    check_for_env_var "$QUEUE_S3_KEY"

    log "FUNCNAME=$FUNCNAME" "DEBUG"

    log "Getting Queue" "INFO"
    queue=$(get_artifact "$ARTIFACT_BUCKET_NAME" "$QUEUE_S3_KEY")
    log "Repo Queue:" "DEBUG"
    log "$queue" "DEBUG"

    log "Creating Commit Item" "INFO"
    commit_item=$(create_commit_item)
    log "Commit Item:" "DEBUG"
    log "$commit_item" "DEBUG"

    #TODO: PR item to only contain most recent commit if status != running 
    log "Adding Commit Item to Queue" "INFO"
    queue=$(add_commit_to_queue "$queue" "$event_item")
    log "Updated PR Queue:" "DEBUG"
    log "$queue" "DEBUG"

    log "Uploading PR Queue" "INFO"
    upload_artifact "$ARTIFACT_BUCKET_NAME" "$QUEUE_S3_KEY" "$queue"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi