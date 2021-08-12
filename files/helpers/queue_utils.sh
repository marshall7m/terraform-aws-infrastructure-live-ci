#!/bin/bash

source utils.sh

get_pr_queue() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    aws s3api get-object \
    --bucket $ARTIFACT_BUCKET_NAME \
    --key $ARTIFACT_BUCKET_PR_QUEUE_KEY \
    pr_queue.json > /dev/null

    echo "$(jq . pr_queue.json)"
}

pr_is_running() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1
    local pull_request_id=$2

    if [[ "$( echo $pr_queue | jq --arg pull_request_id $pull_request_id '.InProgress.ID == $pull_request_id' )" = true ]]; then
        return 0
    else
        return 1
    fi
}

pr_in_queue() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1
    local pull_request_id=$2

    if [[ "$( echo $pr_queue | jq --arg pull_request_id $pull_request_id '(.Queue | map(.ID)) as $queue_ids | $pull_request_id | IN($queue_ids[])' )" = true ]]; then
        return 0
    else
        return 1
    fi
}

commit_to_queue() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1
    local commit_id=$2

    echo "$( echo $pr_queue | jq \
        --arg commit_id $commit_id '
        .InProgress.CommitStack.Queue |= . + [
            {
                "ID": $commit_id
            }
        ]
    ')"
}

pr_to_queue() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1
    local pull_request_id=$2
    local base_ref=$3
    local head_ref=$4

    echo "$( echo $pr_queue | jq \
        --arg pull_request_id $pull_request_id \
        --arg base_ref $base_ref \
        --arg head_ref $head_ref '
        .Queue |= . + [
            {
                "ID": $pull_request_id,
                "BaseRef": $base_ref,
                "HeadRef": $head_ref
            }
        ]
    ')"
}

get_event_vars() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    pull_request_id=$(echo $CODEBUILD_SOURCE_VERSION | cut -d "/" -f 2)
    log "Pull Request ID: ${pull_request_id}" "INFO"

    base_ref=$(echo $CODEBUILD_WEBHOOK_BASE_REF | cut -d "/" -f 3)
    log "Base Ref: ${base_ref}""INFO"

    head_ref=$(echo $CODEBUILD_WEBHOOK_HEAD_REF | cut -d "/" -f 3)
    log "Head Ref: ${head_ref}" "INFO"

    log "Commit ID: ${CODEBUILD_RESOLVED_SOURCE_VERSION}" "INFO"
    log "Build Number: ${CODEBUILD_BUILD_NUMBER}" "INFO"
    log "Artifact Bucket: ${ARTIFACT_BUCKET_NAME}" "INFO"
    log "Bucket Key: ${ARTIFACT_BUCKET_PR_QUEUE_KEY}" "INFO"
}

queue() {
    set -e
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    get_event_vars

    log "Getting PR Queue" "INFO"
    pr_queue=$(get_pr_queue)
    log "PR Queue:" "DEBUG"
    log "$pr_queue" "DEBUG"

    if pr_is_running "$pr_queue" "$pull_request_id"; then
        log "Adding commit to Commit Queue"
        pr_queue=$(commit_to_queue "$pr_queue" "$commit_id")
    elif ! pr_in_queue "$pr_queue" "$pull_request_id"; then
        log "Adding PR to PR Queue" "INFO"
        pr_queue=$(pr_to_queue "$pr_queue" "$pull_request_id" "$base_ref" "$head_ref")
    else
        log "PR is already in Queue" "INFO"
        exit 0
    fi
    
    log "Updated PR Queue:" "DEBUG"
    log "$pr_queue" "DEBUG"

    log "Uploading PR Queue" "INFO"
    upload_pr_queue "$pr_queue"
}