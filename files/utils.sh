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
    log "FUNCNAME=$FUNCNAME" "DEBUG"
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
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    # returns the exitcode instead of the plan output (0=no plan difference, 1=error, 2=detected plan difference)
    terragrunt run-all plan \
        --terragrunt-working-dir $terragrunt_working_dir \
        --terragrunt-non-interactive \
        -detailed-exitcode 2>&1
}

get_git_root() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    echo $(git rev-parse --show-toplevel)
}

get_rel_path() {
    local rel_to=$1
    local path=$2
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    echo "$(realpath -e --relative-to=$rel_to $path)"
}

get_diff_paths() {
    local tg_plan_out=$1
    local git_root=$2
    log "FUNCNAME=$FUNCNAME" "DEBUG"

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

    #input must be expanded bash array (e.g. "${x[*]}")
    local filter=$2

    echo $( echo "$stack" | jq \
        --arg filter "$filter" '
        (try ($filter | split(" ")) // []) as $filter
            | with_entries(select(.key | IN($filter[])))
            | .[].Dependencies |= map_values(select(. | IN($filter[])))
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

    parsed_stack=$(get_parsed_stack "$tg_plan_out" "$git_root" | jq 'map_values({"Dependencies": .})')
    log "JQ Parsed Terragrunt Stack: $parsed_stack" "DEBUG"

    log "Filtering out Terragrunt paths with no difference in plan" "DEBUG"
    stack=$( filter_paths "$parsed_stack" "${diff_paths[*]}" )

    echo "$stack"
}

create_account_stacks() {   
    local approval_mapping=$1

    account_stacks=$(jq -n '{}')
    
    log "Converting Approval Mapping to Bash Array" "DEBUG"
    
    typeset -A accounts

    while IFS== read -r key value; do
        accounts["$key"]="$value"
    done < <(echo $approval_mapping | jq -r '
        to_entries[] 
        | (.value.Dependencies | tostring) as $deps 
        | .value.Paths | .[] | . + "=" + $deps'
    )

    log "Accounts: $( typeset -p accounts )" "DEBUG"

    # gets absolute path to the root of git repo
    git_root=$(get_git_root)
    log "Git Root: $git_root" "DEBUG"
    
    for account in "${!accounts[@]}"; do
        account=$( echo "${account}" | tr -d '"' )
        log "Account: $account" "DEBUG"

        deps="${accounts[$account]}"
        log "Account-Level Dependencies:" "DEBUG"
        log "$deps" "DEBUG"

        log "Getting account stack" "DEBUG"
        stack="$(create_stack $account $git_root)" || exit 1
        
        log "Account stack:" "DEBUG"
        log "$stack" "DEBUG"

        log "Adding account artifact" "DEBUG"
        account_stacks=$( echo "$account_stacks" | jq \
            --arg account $account \
            --arg stack "$stack" \
            --arg deps "$deps" '
            ($stack | fromjson) as $stack
            | ($deps | fromjson) as $deps
            | . + {
                    ($account): {
                        "Dependencies": $deps,
                        "Stack": $stack
                    }
                }' 
        )
    done

    echo "$account_stacks"
}

get_deploy_paths() {
    local deploy_stack=$1


    accounts=$( echo $deploy_stack | jq '
        [to_entries[] | select(.value.Dependencies == []) | .key]
    ')

    log "Getting Deployment Paths from Accounts:" "DEBUG"
    log "$accounts" "DEBUG"

    echo $( echo $deploy_stack | jq \
        --arg accounts "$accounts" '
        ($accounts | fromjson) as $accounts
        | with_entries(select(.key | IN($accounts[])))
        | [.[] | .Stack | to_entries[] | select(.value.Dependencies == []) | .key]
    ')

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

pr_in_progress() {
    local pr_queue=$1

    # returns false if all account stacks and their associated path stacks are empty, true otherwise
    if [[ "$( echo $pr_queue | jq '.InProgress | length > 0' )" = true ]]; then
        return 0
    else
        return 1
    fi
}

get_git_source_versions() {
    local pull_request_id=$1

    base_source_version=refs/heads/$BASE_REF^{$( git rev-parse --verify $BASE_REF )}
    head_source_version=refs/pull/$pull_request_id/head^{$( git rev-parse --verify HEAD )}
}

update_pr_queue_with_deployed_path() {
    local pr_queue=$1
    local deployed_path=$2
    local commit_order_id=$3
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    log "Removing: $deployed_path from Deploy Stack" "DEBUG"
    pr_queue=$( echo $pr_queue | jq \
        --arg deployed_path "$deployed_path" \
        --arg commit_order_id $commit_order_id '
        [($deployed_path | fromjson)] as $deployed_path
        | (.InProgress.CommitStack[$commit_order_id].DeployStack[].Stack[].Dependencies) |= map_values(select(. | IN($deployed_path[]) | not))
    ')

    log "Updated PR Queue: $pr_queue" "DEBUG"
    
    log "Adding: $deployed_path to associated Deployed Array" "DEBUG"
    pr_queue=$( echo $pr_queue | jq \
        --arg commit_order_id $commit_order_id \
        --arg deployed_path "$deployed_path" '
        ($deployed_path | fromjson) as $deployed_path
        | (.InProgress.CommitStack[$commit_order_id].RollbackPaths) |=  [$deployed_path]
    ')

    echo "$pr_queue"
}

is_commit_stack_empty() {
    local pr_queue=$1
    local commit_order_id=$2
    
    bool=$( echo $pr_queue | jq \
        --arg commit_order_id $commit_order_id '
        if .InProgress.CommitStack[$commit_order_id].DeployStack == {} 
        then true
        else false
        end
    ')
    log "results: $bool" "DEBUG"
    if [ "$bool" == true ]; then
        return 1
    else 
        return 0
    fi
}
update_pr_queue_with_next_pr() {
    local pr_queue=$1
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    if [ -z "$pr_queue" ]; then
        log "pr_queue is not defined" "ERROR"
        exit 1
    fi

    if [ -n "$DEPLOY_PULL_REQUEST_ID" ]; then
        log "Overriding Pull Request Queue" "INFO"
        echo "$( echo $pr_queue | jq \
            --arg ID "$DEPLOY_PULL_REQUEST_ID" '
            (.Queue | map(.ID == $ID) | index(true)) as $idx
            | .InProgress = .Queue[$idx] | del(.Queue[$idx])
        ')"
    else
        log "Pulling next Pull Request in queue" "INFO"
        echo "$( echo $pr_queue | jq \
            --arg ID "$DEPLOY_PULL_REQUEST_ID" '
            .InProgress = .Queue[0] | del(.Queue[0])
            '
        )"
    fi
}

update_pr_queue_with_new_commit_stack() {
    set -e
    local pull_request_id=$1
    local pr_queue=$2
    
    log "Creating new Deployment Stack" "INFO"
    
    get_git_source_versions $pull_request_id
    log "Base Ref Source Version: $base_source_version" "DEBUG"
    log "Head Ref Source Version: $head_source_version" "DEBUG"

    approval_mapping=$(get_approval_mapping)
    log "Approval Mapping:" "DEBUG"
    log "$approval_mapping" "DEBUG"

    commit_order_id=$( echo $pr_queue | jq '
        .InProgress.CommitStack as $commit_stack
        | if $commit_stack != null then $commit_stack | keys | map(. | tonumber) | max + 1 else 1 end
    ')
    log "Commit Order ID: $commit_order_id" "INFO"

    log "Getting Stacks" "INFO"
    account_stacks=$(create_account_stacks "$approval_mapping")
    log "Account Stacks" "DEBUG"
    log "$account_stacks" "DEBUG"
    log "Adding Stacks to PR Queue"  "INFO"
    echo "$( echo "$pr_queue" | jq \
        --arg commit_order_id "$commit_order_id" \
        --arg account_stacks "$account_stacks" \
        --arg base_source_version "$base_source_version" \
        --arg head_source_version "$head_source_version" '
        ($account_stacks | fromjson) as $account_stacks
        | (.InProgress.CommitStack) |= . + {
            ($commit_order_id): {
                "DeployStack": $account_stacks,
                "InitialDeployStack": $account_stacks,
                "BaseSourceVersion": $base_source_version,
                "HeadSourceVersion": $head_source_version
            }
        }
        '
    )"
}

update_pr_queue_with_rollback_stack() {
    local pr_queue=$1
    local commit_order_id=$2

    readarray -t filter_paths < <( echo $pr_queue | jq -c \
        --arg commit_order_id $commit_order_id '
        .InProgress.CommitStack[$commit_order_id].RollbackPaths
    ')

    initial_stack=$( echo $pr_queue | jq \
        --arg commit_order_id $commit_order_id '
        .InProgress.CommitStack[$commit_order_id].InitialDeployStack
    ')

    log "Filtering out Terragrunt paths that don't need to be rolled back" "DEBUG"
    deploy_stack=$( filter_paths "$initial_stack" "${filter_paths[*]}" )
}

trigger_sf() {
    set -e
    log "Getting PR queue" "INFO"
    pr_queue=$(get_pr_queue)
    
    if [ "$CODEBUILD_INITIATOR" == "$EVENTBRIDGE_RULE" ]; then
        log "Triggered via Step Function Event" "INFO"
        
        sf_event=$( echo $EVENTBRIDGE_EVENT | jq '. | fromjson')
        deployed_path=$( echo $sf_event | jq '.Path')
        deployment_type=$( echo $sf_event | jq '.DeploymentType')
        status=$( echo $sf_event | jq '.Status')
        base_commit_id=$( echo $sf_event | jq '.BaseSourceVersion' | grep -oP '(?<=\{).+?(?=\})')
        head_commit_id=$( echo $sf_event | jq '.HeadSourceVersion' | grep -oP '(?<=\{).+?(?=\})')
        commit_order_id=$( echo $sf_event | jq '.CommitOrderID')
        
        log "Step Function Event:" "DEBUG"
        log "$sf_event" "DEBUG"

        pr_queue=$( update_pr_queue_with_deployed_path "$pr_queue" "$deployed_path" "$commit_order_id" )
        log "Updated PR Queue:" "DEBUG"
        log "$pr_queue" "DEBUG"

        if [ "$status" == "FAILED" ]; then
            deployment_type="RollbackStack"
            
            update_pr_queue_with_rollback_stack $pr_queue $commit_order_id
            deploy_stack=$( echo $pr_queue | jq \
                --arg commit_order_id $commit_order_id '
                .InProgress.CommitStack[$commit_order_id].RollbackStack
            ')
        fi

    elif [ "$CODEBUILD_INITIATOR" == "user" ]; then  
        if pr_in_progress "$pr_queue"; then
            log "Pull Request in Progress -- Deploying multiple PR concurrently is not advised" "INFO"
            exit 1
        else
            new_commit=true
            pr_queue=$(update_pr_queue_with_next_pr "$pr_queue")
            log "Updated PR Queue: $pr_queue" "DEBUG"
            log "$pr_queue" "DEBUG"

            pull_request_id=$( echo $pr_queue | jq '.InProgress | .ID')
            log "Pull Request Id: $pull_request_id" "INFO"
            head_ref=$( echo $pr_queue | jq '.InProgress | .BaseRef' )

            log "Locking Deployments only from PR" "INFO"
            create_pr_codebuild_webhook $BUILD_NAME $BASE_REF $head_ref
            
            log "Checking out PR Head" "INFO"
            checkout_pr $pull_request_id
        fi

    elif [ -n  $CODEBUILD_WEBHOOK_TRIGGER ]; then
        new_commit=true

        log "New commits were added" "INFO"

        pull_request_id=$( echo "${CODEBUILD_WEBHOOK_TRIGGER}" | cut -d '/' -f 2 )
        log "Pull Request ID: $pull_request_id" "DEBUG"

        #TODO: Add $RELEASE_CHANGES condition
        stop_running_sf_executions
    fi

    if [ -n "$new_commit" ]; then
        pr_queue=$(update_pr_queue_with_new_commit_stack $pull_request_id $pr_queue)
        log "Updated PR Queue:" "INFO"
        log "$pr_queue" "DEBUG"
        deploy_stack=$( echo $pr_queue | jq \
            --arg commit_order_id $commit_order_id '
            .InProgress.CommitStack[$commit_order_id].DeployStack
        ')
    fi

    log "Deployment Stack" "DEBUG"
    log "$deploy_stack" "DEBUG"

    deploy_paths=$(get_deploy_paths "$deploy_stack")
    log "Deploy Paths:" "DEBUG"
    log "$deploy_paths" "DEBUG"

    log "Starting Step Function Deployment Flow" "INFO"
    start_sf_executions $deploy_paths

    log "Uploading Updated PR Queue" "INFO"
    upload_pr_queue $pr_queue
}

