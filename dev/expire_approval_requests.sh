declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="DEBUG"

log() {
    local log_message=$1
    local log_priority=$2

    #check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    #check if level is enough
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2

    #log here
    echo "${log_priority} : ${log_message}"
}

expire_approval_requests() {
    local bucket=$1
    local key=$2

    execution_path=$(basename $key)
    
    log "Getting Execution Artifact" "INFO"
    aws s3api get-object \
        --bucket $bucket \
        --key $key \
        "$execution_path" > /dev/null

    execution=$(jq . "$execution_path")
    log "Current Execution:" "DEBUG"
    log "$execution" "DEBUG"

    log "Updating Approval Status" "INFO"
    updated_execution=$(echo $execution | jq '.PlanUptoDate = false')
    log "Updated Execution:" "DEBUG"
    log "$updated_execution" "DEBUG"

    log "Uploading Updated Execution Artifact" "INFO"
    aws s3api put-object \
        --bucket $bucket \
        --key $key \
        --body "$execution_path" > /dev/null
}

expire_approval_requests $1 $2