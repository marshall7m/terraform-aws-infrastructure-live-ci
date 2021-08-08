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

get_tg_plan_out() {
    local terragrunt_working_dir=$1
    # returns the exitcode instead of the plan output (0=no plan difference, 1=error, 2=detected plan difference)
    terragrunt run-all plan \
        --terragrunt-working-dir $terragrunt_working_dir \
        --terragrunt-non-interactive \
        -detailed-exitcode 2>&1
}

get_git_root() {
    echo $(git rev-parse --show-toplevel)
}

get_rel_path() {
    local rel_to=$1
    local path=$2

    echo "$(realpath -e --relative-to=$rel_to $path)"
}

get_diff_paths() {
    local tg_plan_out=$1
    local git_root=$2

    # Get git repo root path relative path to the directories that terragrunt detected a difference between their tf state and their cfg
    # use (\n|\s|\t)+ since output format may differ between terragrunt versions
    # use grep for single line parsing to workaround lookbehind fixed width constraint
    # diff_paths=($(echo "$tg_plan_out" \
    #     | pcregrep -M 'exit\s+status\s+2(\n|\s|\t)+prefix=\[(.+)?(?=\])' \
    #     | grep -oP 'exit\s+status\s+2.+?prefix=\[\K(.+)?(?=\])' \
    #     | get_rel_path "$rel_to"
    # ))

    # echo $( echo "$tg_plan_out" | grep -oP 'exit\s+status\s+2.+?prefix=\[\K(.+)?(?=\])')
    # echo $( echo "$tg_plan_out" \
    #     | pcregrep -M 'exit\s+status\s+2(\n|\s|\t)+prefix=\[(.+)?(?=\])' \
    #     | grep -oP 'exit\s+status\s+2.+?prefix=\[\K(.+)?(?=\])'
    # )
    # use pcregrep with -M multiline option to scan terragrunt plan output for
    # directories that exited plan with exit status 2 (diff in plan)
    # -N flag defines the convention for newline and CRLF defines any of the conventions
    echo $( echo "$tg_plan_out" \
        | pcregrep -Mo -N CRLF '(?<=exit\sstatus\s2\n).+?(?=\])' \
        | grep -oP 'prefix=\[\K.+' \
        | get_rel_path "$git_root"
    )
}

get_parsed_stack() {
    local tg_plan_out=$1
    local git_root=$2
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    raw_stack=$( echo $tg_plan_out | grep -oP '=>\sModule\K.+?(?=\))' )

    log "Raw Stack:" "DEBUG"
    log "${raw_stack[*]}" "DEBUG"
    
    parsed_stack=$(jq -n '{}')
    while read -r line; do
        log "" "DEBUG"
        log "Stack Layer: $(printf "\n\t%s\n" "$line")" "DEBUG"

        parent=$( echo "$line" \
            | grep -Po '.+?(?=\s\(excluded:)' \
            | get_rel_path "$git_root" 
        )
        log "Parent: $(printf "\n\t%s" "${parent}")" "DEBUG"

        deps=($( echo "$line" \
            | grep -Po 'dependencies:\s+\[\K.+?(?=\])' \
            | grep -Po '\/.+?(?=,|$)' \
            | get_rel_path "$git_root"
        ))
        log "Dependencies: $(printf "\n\t%s" "${deps[@]}")" "DEBUG"

        parsed_stack=$( echo $parsed_stack \
            | jq --arg parent "$parent" --arg deps "$deps" '
                .[$parent] += try ($deps | split("\n") | reverse) // []' 
        )
    done <<< "$raw_stack"

    echo "$parsed_stack"
}

filter_paths() {
    local stack=$1

    #input must be expanded bash array ("${x[*]}")
    local filter=$2

    echo $( echo "$stack" | jq \
        --arg filter "$filter" '
        (try ($filter | split(" ")) // []) as $filter
            | with_entries(select(.key | IN($filter[])))
            | map_values([.[] | select(. | IN($filter[])) ])
        '
    )
}

create_stack() {
    local terragrunt_working_dir=$1
    local git_root=$2

    tg_plan_out=$(get_tg_plan_out $terragrunt_working_dir)
    exitcode=$?
    if [ $exitcode -eq 1 ]; then
        log "Error running terragrunt commmand" "ERROR"
        log "Command Output:" "ERROR"
        log "$tg_plan_out" "ERROR"
        exit 1
    fi
    diff_paths=($(get_diff_paths "$tg_plan_out" "$git_root"))
    log "Terragrunt Paths with Detected Difference: $(printf "\n\t%s" "${diff_paths[@]}")" "DEBUG"

    num_diff_paths="${#diff_paths[@]}"
    log "Count: $num_diff_paths" "DEBUG"

    parsed_stack=$(get_parsed_stack "$tg_plan_out" "$git_root")
    log "JQ Parsed Terragrunt Stack: $parsed_stack" "DEBUG"

    log "Filtering out Terragrunt paths with no difference in plan" "DEBUG"
    stack=$( filter_paths "$parsed_stack" "${diff_paths[*]}" )

    echo "$stack"
}

create_account_stacks() {   
    local approval_mapping=$1

    account_stacks=$(jq -n '{}')
    
    log "Converting Approval Mapping to Bash Array" "DEBUG"
    readarray -t approval_mapping < <( echo "$approval_mapping" | jq -c '.[] | .Paths | .[]' )
    log "Account Array: ${approval_mapping[*]}" "DEBUG"

    # gets absolute path to the root of git repo
    git_root=$(get_git_root)
    log "Git Root: $git_root" "DEBUG"
    
    for account in "${approval_mapping[@]}"; do
        account=$( echo "${account}" | tr -d '"' )
        
        log "account: $account" "DEBUG"

        log "Getting account stack" "DEBUG"
        stack=$(create_stack $account $git_root) || exit 1
        
        log "Account stack:" "DEBUG"
        log "$stack" "DEBUG"

        log "Adding account artifact" "DEBUG"
        account_stacks=$( echo "$account_stacks" | jq \
            --arg account $account \
            --arg stack "$stack" '
            ($stack | fromjson) as $stack
            | . +  {
                    ($account): {
                        "Stack": $stack
                    }
                }' 
        )
    done

    echo "$account_stacks"
}

get_deploy_stack() {
    local stack=$1
    readarray -t approval_mapping < <( echo "$stack" | jq -c '.[] | .keys | .[]' )
    account_stack=$(echo "$stack" | jq '.AccountStack')
    pop_stack "$stack"

    account_peek=$peek
    account_stack=$updated_stack

    declare -A deploy_stack
    for account in "${account_peek[@]}"; do
        account_stack=$(echo $stack | jq '.AccountStack')
        deploy_stack+=($)
    done
}

pop_stack() {
    stack=$1

    log "Getting peek" "DEBUG"
    peek=$( echo $stack | jq '[to_entries[] | select(.value == []) | .key]')
    log "Peek:" "DEBUG"
    log "$peek" "DEBUG"

    log "Getting updated stack" "DEBUG"
    updated_stack=$( echo $stack | jq --arg peek "$peek" '
        ($peek | fromjson) as $peek 
            | with_entries(select(.key 
            | IN($peek[]) | not))' 
    )
    log "Updated Stack:" "DEBUG"
    log "$updated_stack" "DEBUG"

    log ""
}

checkout_pr() {
    local pull_request_id=$1

    git fetch origin pull/$pull_request_id/head:pr-${pull_request_id}
    git checkout pr-${pull_request_id}
}

get_pr_queue() {
    aws s3api get-object \
    --bucket $ARTIFACT_BUCKET_NAME \
    --key $ARTIFACT_BUCKET_PR_QUEUE_KEY \
    pr_queue.json > /dev/null

    echo $(jq . pr_queue.json)
}

stop_running_sf_executions() {

    current_execution_arn=$(aws stepfunctions list-executions \
            --state-machine-arn $STATE_MACHINE_ARN \
            --status-filter "RUNNING" | jq '.executions | .[] | .executionArn'
        )

    log "Stopping Step Function execution: $current_execution_arn" "INFO"
    aws stepfunctions stop-execution \
        --execution-arn $current_execution_arn \
        --cause "New commits were added to pull request"
}

get_approval_mapping() {
    aws s3api get-object \
        --bucket $ARTIFACT_BUCKET_NAME \
        --key $APPROVAL_MAPPING_S3_KEY \
        approval_mapping.json > /dev/null

    echo $(jq . approval_mapping.json)
}

start_sf_executions() {
    local execution_name=$1
    local sf_input=$2

    aws stepfunctions start-execution \
        --state-machine-arn $STATE_MACHINE_ARN \
        --name "${execution_name}" \
        --input $sf_input
}

upload_pr_queue() {
    local pr_queue=$1

    echo "$pr_queue" > $pr_queue.json
    aws s3api put-object \
        --acl private \
        --body ./pr_queue.json \
        --bucket $ARTIFACT_BUCKET_NAME \
        --key $ARTIFACT_BUCKET_PR_QUEUE_KEY.json
}

check_stack_progress() {
    local pr_queue=$1

    # returns false if all account stacks and their associated path stacks are empty, true otherwise
    if [[ "$( echo $pr_queue | jq '[.InProgress | .. | .Stack? // empty | length == 0 ] | all | not' )" = true ]]; then
        return 1
    else
        return 0
    fi
}

get_git_source_versions() {
    local pull_request_id=$1

    base_source_version=refs/heads/$BASE_REF^{$( git rev-parse --verify $BASE_REF )}
    head_source_version=refs/pull/$pull_request_id/head^{$( git rev-parse --verify HEAD )}
}


trigger_sf() {
    set -e

    log "Getting PR queue" "INFO"
    pr_queue=$(get_pr_queue)

    log "EVENTBRIDGE_RULE: $EVENTBRIDGE_RULE" "DEBUG"
    
    if [ "$CODEBUILD_INITIATOR" == "$EVENTBRIDGE_RULE" ]; then
        log "Triggered via Step Function Event" "INFO"
        
        sf_event=$( echo $EVENTBRIDGE_EVENT | jq '. | fromjson')
        deployed_path=$( echo $sf_event | jq '.Path')
        status=$( echo $sf_event | jq '.Status')

        head_ref_prev_commit=$(git log --format="%H" -n 1 --skip 1)
        pr_queue=$( echo $pr_queue | jq \
            --arg commit_id $commit_id \
            --arg deployed_path $deployed_path '.CommitStack 
            | .["$commit"] 
            | .Deployed
            | . + [$deployed_path]
        ')
        log "Commit Stack:" "DEBUG"
        log "$commit_stack" "DEBUG"

        if [ "$status" == "SUCCESS" ]; then
            pr_queue=$( echo $pr_queue | jq \
                --arg commit_id $commit_id \
                --arg deployed_path $deployed_path '
                [$deployed_path] as $deployed_path
                | .CommitStack
                | .["$commit"] 
                | .DeployStack
                | map_values([.[] | select(. | IN($deployed_stack[] | not)) ])
            ')
        elif [ "$status" == "FAILED" ]; then

        else
            log "Handling for Step Function Status: $status is not defined" "ERROR"
            exit 1

    elif check_stack_progress "$pr_queue"; then
        create_new_artifact=true

        log "Pulling next Pull Request from queue" "INFO"
        pr_queue=$( echo $pr_queue | jq '.InProgress = .Queue[0] | del(.Queue[0])' )
        pull_request_id=$( echo $pr_queue | jq '.InProgress | .ID')
        log "Pull Request Id: $pull_request_id" "INFO"
        head_ref=$( echo $pr_queue | jq '.InProgress | .BaseRef' )

        log "Locking Deployments only from PR" "INFO"
        create_pr_codebuild_webhook $BUILD_NAME $BASE_REF $head_ref
        
        log "Checking out PR Head" "INFO"
        checkout_pr $pull_request_id

    elif [ -n  $CODEBUILD_WEBHOOK_TRIGGER ]; then
        create_new_artifact=true

        log "New commits were added" "INFO"

        pull_request_id=$( echo "${CODEBUILD_WEBHOOK_TRIGGER}" | cut -d '/' -f 2 )
        log "Pull Request ID: $pull_request_id" "DEBUG"

        stop_running_sf_executions
    fi

    if [ -n $create_new_artifact ]; then
        log "Creating new Deployment Stack" "INFO"
        
        get_git_source_versions $pull_request_id
        log "Base Ref Source Version: $base_source_version" "DEBUG"
        log "Head Ref Source Version: $head_source_version" "DEBUG"

        approval_mapping=$(get_approval_mapping)
        log "Approval Mapping:" "DEBUG"
        log "$approval_mapping" "DEBUG"

        log "Getting Stacks" "INFO"
        account_stacks=$(create_account_stacks "$approval_mapping")
        log "Account Stacks" "DEBUG"
        log "$account_stacks" "DEBUG"

        log "Adding Stacks to PR Queue"  "INFO"
        pr_queue=$( echo "$pr_queue" | jq \
            --arg account_stacks "$account_stacks" \
            --arg base_source_version "$base_source_version" \
            --arg head_source_version "$head_source_version" '
            ($account_stacks | fromjson) as $account_stacks
            | .InProgress | . + {
                "Stack": $account_stacks,
                "BaseSourceVersion": $base_source_version,
                "HeadSourceVersion": $head_source_version
            }
            '
        )
        
        log "Updated PR Stack:" "DEBUG"
        log "$pr_queue" "DEBUG"
    fi

    log "Getting Deployment Stack" "INFO"
    get_deploy_stack $pr_queue

    log "Uploading Updated PR Queue" "INFO"
    upload_pr_queue $pr_queue

    log "Starting Executions" "INFO"
}

