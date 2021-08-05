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

get_tg_plan_out() {
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
}

get_git_root() {
    git_root=$(git rev-parse --show-toplevel)
}

get_rel_path() {
    local rel_to=$1
    local path=$2

    echo "$(xargs realpath -e --relative-to=$rel_to $path)"
}

create_stack() {
    local terragrunt_working_dir=$1

    tg_plan_out=$(get_tg_plan_out $terragrunt_working_dir)
    # gets absolute path to the root of git repo
    
    git_root=$(get_git_root)
    echo "$git_root"
    exit 1
    # Get git repo root path relative path to the directories that terragrunt detected a difference between their tf state and their cfg
    # use (\n|\s|\t)+ since output format may differ between terragrunt versions
    # use grep for single line parsing to workaround lookbehind fixed width constraint
    diff_paths=($(echo "$tg_plan_out" | pcregrep -M 'exit\s+status\s+2(\n|\s|\t)+prefix=\[(.+)?(?=\])' | grep -oP '(?<=prefix=\[).+?(?=\])' | get_rel_path "$git_root" $1))
    echo "blue"
    echo "${diff_paths[*]}"
    exit 1
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
        parent=$( echo "$line" | grep -Po '.+?(?=\s\(excluded:)' | get_rel_path $git_root $1 )
        deps=$( echo "$line" | grep -Po 'dependencies:\s+\[\K.+?(?=\])' | grep -Po '.+?(?=,\s|$)' | get_rel_path "$git_root" $1 )
        
        log "Parent: $(printf "\n\t%s" "${parent}")" "DEBUG"
        log "Dependencies: $(printf "\n\t%s" "${deps}")" "DEBUG"
        
        #TODO: filter out deps that haven't changed
        if [[ " ${diff_paths[@]} " =~ " ${parent} " ]]; then
            log "Found difference in plan" "DEBUG"
            stack=$( echo $stack | jq --arg parent "$parent" --arg deps "$deps" '.[$parent] += try ($deps | split("\n") | reverse) // []' )
        else
            log "Detected no difference in terraform plan for directory: ${parent}" "DEBUG"
        fi
    done <<< "$raw_stack"

    echo "$stack"
}

create_account_stacks() {
    local approval_mapping="$1"

    account_stacks=$(jq -n '{}')

    #converts jq array to bash array
    readarray -t approval_mapping < <( echo "$approval_mapping" | jq -c 'keys | .[]' )
    log "Account Array: ${approval_mapping[*]}" "DEBUG"

    for account in "${approval_mapping[@]}"; do
        account=$( echo "${account}" | tr -d '"' )
        
        log "account: $account" "DEBUG"

        log "Getting account stack" "DEBUG"
        stack=$(create_stack $account)
        
        log "Account stack:" "DEBUG"
        log "$stack" "DEBUG"

        log "Adding account artifact" "DEBUG"
        account_stacks=$(echo $account_stacks | jq \
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

    account_stack=$(echo $stack | jq '.AccountStack')
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
            | with_entries(select([.key] 
            | inside($peek) | not))' 
    )
    log "Updated Stack:" "DEBUG"
    log "$updated_stack" "DEBUG"
}

create_commit_stack() {
    #TODO: Figure out why func doesn't output stdout
    local base_source_version="$1"
    local head_source_version="$2"
    local approval_mapping="$3"
    exit 1
    log "Creating Account Approval Stacks" "INFO"
    account_stacks=$(create_account_stacks "$approval_mapping")

    log "Creating Execution" "INFO"
    echo $(jq -n \
        --arg account_stacks "$account_stacks" \
        --arg base_source_version $base_source_version \
        --arg head_source_version $head_source_version '
            | ($account_stacks | fromjson) as $account_stacks
            | {
                "BaseSourceVersion": $base_source_version,
                "HeadSourceVersion": $head_source_version
            } + $account_stacks'
    )
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
    in_progress=$( echo $pr_queue | jq '[.InProgress | .. | .Stack? // empty | length == 0 ] | all | not' )
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

    log "Checking if there's a PR in progress" "INFO"
    check_stack_progress "$pr_queue"

    if [ "$in_progress"  == false ]; then
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
        # stack=$(create_commit_stack \
        #     "$base_source_version" \
        #     "$head_source_version" \
        #     "$approval_mapping"
        # )
        stack=$( create_commit_stack "foo" "bar" "baz" )

        log "Adding Stacks to PR Queue"  "INFO"
        pr_queue=$( echo $pr_queue | jq \
            --arg stack $stack '
            .Queue.Stack = $stack
            '
        )
        
        log "Updated PR Stack:" "DEBUG"
        log "$pr_queue" "DEBUG"
    fi
    exit 1
    log "Getting Deployment Stack" "INFO"
    get_deploy_stack $commit_stack

    log "Uploading Updated PR Queue" "INFO"
    upload_pr_queue $pr_queue

    log "Starting Executions" "INFO"

}