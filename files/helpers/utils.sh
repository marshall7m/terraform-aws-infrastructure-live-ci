#!/bin/bash

log() {
    declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
    local log_message=$1
    local log_priority=$2

    #check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    #check if level is enough
    # returns exit status 0 instead of 2 to prevent `set -e ` from exiting if log priority doesn't meet log level
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return

    # redirects log message to stderr (>&2) to prevent cases where sub-function
    # uses log() and sub-function stdout results and log() stdout results are combined
    echo "${log_priority} : ${log_message}" >&2
}

get_pr_queue() {
    aws s3api get-object \
    --bucket $ARTIFACT_BUCKET_NAME \
    --key $ARTIFACT_BUCKET_PR_QUEUE_KEY \
    pr_queue.json > /dev/null

    echo $(jq . pr_queue.json)
}