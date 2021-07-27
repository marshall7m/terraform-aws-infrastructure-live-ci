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

update_codebuild_webhook() {

    local project_name=$1
    local base_ref=$2
    local head_ref=$3

    log "Codebuild Project Name: ${project_name}" "DEBUG"
    log "Base Ref: ${base_ref}" "DEBUG"
    log "Head Ref: ${head_ref}" "DEBUG"

    filter_group=$(jq -n \
        --arg BASE_REF $base_ref \
        --arg HEAD_REF $head_ref \
        '[
            [
                {
                    "type": "EVENT",
                    "pattern": "PULL_REQUEST_UPDATED"
                },
                {
                    "type": "BASE_REF",
                    "pattern": "refs/heads/\($BASE_REF)"
                },
                {
                    "type": "HEAD_REF",
                    "pattern": "refs/heads/\($HEAD_REF)"
                }
            ]
        ]')

    log "Filter Group:"  "DEBUG"
    log "$filter_group" "DEBUG"

    log "Updating Build Webhook" "DEBUG"
    aws codebuild update-webhook \
        --project-name $project_name \
        --filter-groups $filter_group
}

update_codebuild_webhook $1 $2 $3