#!/bin/bash

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="${script_logging_level:="DEBUG"}"

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

create_stack() {
    local terragrunt_working_dir=$1

    # returns the exitcode instead of the plan output (0=no plan difference, 1=error, 2=detected plan difference)
    tg_plan_out=$(terragrunt run-all plan --terragrunt-working-dir $terragrunt_working_dir --terragrunt-non-interactive -detailed-exitcode 2>&1)
    exitcode=$?
    if [ $exitcode -eq 1 ]; then
        # TODO: Handle directories with to-be-created remote backends once terragrunt issue is resolved: https://github.com/gruntwork-io/terragrunt/issues/1747
        # see if error is related to remote backend state not being initialized
        if [ ${#new_remote_state} -ne 0 ]; then
            log "Directories with new backends:" "DEBUG"
            log "${new_remote_state[*]}" "DEBUG"
        else
            log "Error running terragrunt commmand" "ERROR" >&2
            log "Command Output:" "ERROR" >&2
            log "$tg_plan_out" "ERROR" >&2
            exit 1
        fi
    fi

    # gets absolute path to the root of git repo
    git_root=$(git rev-parse --show-toplevel)

    # Get git repo root path relative path to the directories that terragrunt detected a difference between their tf state and their cfg
    # use (\n|\s|\t)+ since output format may differ between terragrunt versions
    # use grep for single line parsing to workaround lookbehind fixed width constraint
    diff_paths=($(echo "$tg_plan_out" | pcregrep -M 'exit\s+status\s+2(\n|\s|\t)+prefix=\[(.+)?(?=\])' | grep -oP '(?<=prefix=\[).+?(?=\])' | xargs realpath -e --relative-to="$git_root"))

    if [ ${#diff_paths[@]} -ne 0 ]; then
        log "Directories with difference in terraform plan:" "DEBUG"
        log "$(printf "\n\t%s" "${diff_paths[*]}")" "DEBUG"
    else
        log "Detected no directories with differences in terraform plan" "INFO"
        log "Command Output:" "DEBUG"
        log "$tg_plan_out" "DEBUG"
        exit 1
    fi

    # terragrunt run-all plan run order
    raw_stack=$( echo $tg_plan_out | grep -oP '=>\sModule\K.+?(?=\))' )
    log "Raw Stack: $(printf "\n\t%s" "$raw_stack")" "DEBUG"

    stack=$(jq -n '{}')

    while read -r line; do
        log "Stack Layer: $(printf "\n\t%s\n" "$line")" "DEBUG"
        parent=$( echo "$line" | grep -Po '.+?(?=\s\(excluded:)' | xargs realpath -e --relative-to="$git_root" )
        deps=$( echo "$line" | grep -Po 'dependencies:\s+\[\K.+?(?=\])' | grep -Po '.+?(?=,\s|$)' | xargs realpath -e --relative-to="$git_root" )
        
        log "Parent: $(printf "\n\t%s" "${parent}")" "DEBUG"
        log "Dependencies: $(printf "\n\t%s" "${deps}")" "DEBUG"

        if [[ " ${diff_paths[@]} " =~ " ${parent} " ]]; then
            log "Found difference in plan" "DEBUG"
            stack=$( echo $stack | jq --arg parent "$parent" --arg deps "$deps" '.[$parent] += try ($deps | split("\n") | reverse) // []' )
        else
            log "Detected no difference in terraform plan for directory: ${parent}" "DEBUG"
        fi
    done <<< "$raw_stack"
}


create_source_versions() {
    source_versions=$(jq -n '{
        "source_version": $source_version,
        "rollback_source_version": $rollback_source_version
    }')
}

create_account_stacks() {
    
    aws s3api get-object \
    --bucket $ARTIFACT_BUCKET_NAME \
    --key $APPROVAL_MAPPING_S3_KEY \
    approval_mapping.json > /dev/null

    approval_mapping=$(jq . approval_mapping.json)
    log "Approval Mapping:" "DEBUG"
    log "$approval_mapping" "DEBUG"

    account_stacks=$(jq -n '{}')
    while read -r account; do
        log "account: $account" "DEBUG"

        log "Getting account stack" "DEBUG"
        create_stack $account || exit 1
        
        log "Account stack:" "DEBUG"
        log "$stack" "DEBUG"

        log "Adding account artifact" "DEBUG"
        account_stacks=$(echo $account_stacks | jq \
            --arg account $account \
            --arg stack "$stack" '
                ($stack | fromjson) as $stack
                | . +  {
                        ($account): {
                            "Stack": $stack,
                            "StackQueue": $stack
                        }
                    }' )
        
        log "Execution:" "DEBUG"
        log "$execution" "DEBUG"
    done <<< $(echo $approval_mapping | jq -r 'keys | .[]')

}

create_execution_artifact() {

    #join all artifact pieces into single json

    create_source_versions
    create_account_stacks

    execution=$(jq -n \
        --arg account_stacks $account_stacks \
        --arg repo_versions $source_versions \
        '$account_stacks + $repo_versions'
    )
}

trigger_sf() {
    sf_name="${pull_request_id}-${head_ref_current_commit_id}"
    log "Execution Name: ${sf_name}" "INFO"

    create_execution_artifact

    execution > execution.json
    log "Uploading execution artifact to S3" "INFO"
    aws s3api put-object \
        --acl private \
        --body $execution_file_path \
        --bucket $
        --key executions/$execution_id.json

    log "Starting Execution" "INFO"
    aws stepfunctions start-execution \
        --state-machine-arn $STATE_MACHINE_ARN \
        --name "${sf_name}" \
        --input "${sf_input}"
}
