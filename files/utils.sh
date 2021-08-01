#!/bin/bash

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="${script_logging_level:="INFO"}"

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

create_pr_codebuild_webhook() {

    local build_name=$1
    local base_ref=$2
    local head_ref=$3

    log "Codebuild Project Name: ${build_name}" "DEBUG"
    log "Base Ref: ${base_ref}" "DEBUG"
    log "Head Ref: ${head_ref}" "DEBUG"

    #TODO: Add filepath filter for .hcl|.tf files from account paths
    filter_group=$(jq -n \
        --arg base_ref $base_ref \
        --arg head_ref $head_ref \
        '[
            [
                {
                    "type": "EVENT",
                    "pattern": "PULL_REQUEST_UPDATED"
                },
                {
                    "type": "BASE_REF",
                    "pattern": "refs/heads/\($base_ref)"
                },
                {
                    "type": "HEAD_REF",
                    "pattern": "refs/heads/\($head_ref)"
                }
            ]
        ]')

    log "Filter Group:"  "DEBUG"
    log "$filter_group" "DEBUG"

    log "Updating Build Webhook" "DEBUG"
    aws codebuild update-webhook \
        --project-name $build_name \
        --filter-groups $filter_group
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
    local base_source_version=$1
    local head_source_version=$2

    # Allows faster Codebuild builds since it only downloads PR instead of entire repo
    source_versions=$(jq -n \
        --arg base_source_version $base_source_version \
        --arg head_source_version $head_source_version '
        {
            "BaseSourceVersion": $base_source_version,
            "HeadSourceVersion": $head_source_version
        }'
    )
}

create_account_stacks() {
    local approval_mapping=$1

    account_stacks=$(jq -n '{}')

    #converts jq array to bash array
    readarray -t approval_mapping < <( echo $approval_mapping | jq -c 'keys | .[]' )
    log "Account Array: ${approval_mapping[*]}" "DEBUG"

    for account in "${approval_mapping[@]}"; do
        account=$( echo "${account}" | tr -d '"' )
        
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
                }' 
        )
    done
}

create_execution_artifact() {

    local base_source_version=$1
    local head_source_version=$2
    local approval_mapping=$3
    
    log "Creating Source Version" "INFO"
    create_source_versions $base_source_version $head_source_version

    log "Creating Account Approval Stacks" "INFO"
    create_account_stacks "$approval_mapping"

    log "Creating Execution" "INFO"
    execution=$(jq -n \
        --arg account_stacks "$account_stacks" \
        --arg source_versions "$source_versions" '
        ($source_versions | fromjson) as $source_versions
            | ($account_stacks | fromjson) as $account_stacks
            | $source_versions + $account_stacks'
    )
}