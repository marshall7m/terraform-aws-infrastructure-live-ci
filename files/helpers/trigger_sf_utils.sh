#!/bin/bash

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
source "$DIR/utils.sh"

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

    stack=$(get_parsed_stack "$tg_plan_out" "$git_root" | jq 'map_values({"Status": "Waiting", "Dependencies": .})')
    log "Terragrunt Dependency Stack: $stack" "DEBUG"

    log "Filtering out Terragrunt paths with no difference in plan" "DEBUG"
    stack=$( filter_paths "$stack" "${diff_paths[*]}" )
    
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
                        "Status": "Waiting",
                        "Dependencies": $deps,
                        "Stack": $stack
                    }
                }' 
        )
    done

    echo "$account_stacks"
}

get_target_paths() {
    local target_stack=$1

    log "Getting list of accounts that have no account dependencies or account dependencies that are not running" "DEBUG"
    accounts=$( echo $target_stack | jq '
        (.) as $target_stack
        | ["RUNNING", "WAITING"] as $unfinished_status
        | [to_entries[] | select(.value.Dependencies | map($target_stack[.].Status? | IN($unfinished_status[]) | not or . == null) | all) | .key ]
    ')

    log "Getting Deployment Paths from Accounts:" "DEBUG"
    log "$accounts" "DEBUG"

    echo "$( echo $target_stack | jq \
        --arg accounts "$accounts" '
        ($accounts | fromjson) as $accounts
        | with_entries(select(.key | IN($accounts[])))
        | [.[] | (.Stack) as $stack | $stack | to_entries[] | select(.value.Status == "WAITING" and (.value.Dependencies | map($stack[.].Status == "SUCCESS" or . == null ) | all) ) | .key]
    ')"

}

checkout_pr() {
    local pull_request_id=$1
    local commit_id=$2

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
    running_executions=$(aws stepfunctions list-executions \
        --state-machine-arn $STATE_MACHINE_ARN \
        --status-filter "RUNNING" | jq '.executions | map(.executionArn)'
    )

    for execution in "${running_executions[@]}"; do
        log "Stopping Step Function execution: $execution" "DEBUG"
        aws stepfunctions stop-execution \
            --execution-arn "$execution" \
            --cause "Releasing most recent commit changes"
    done
    
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

pr_in_progress() {
    local pr_queue=$1

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
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    log "Removing: $deployed_path from Deploy Stack" "DEBUG"
    pr_queue=$( echo $pr_queue | jq \
        --arg deployed_path "$deployed_path" '
        [($deployed_path | fromjson)] as $deployed_path
        | (.InProgress.CommitStack.InProgress.DeployStack[].Stack[].Dependencies) |= map_values(select(. | IN($deployed_path[]) | not))
    ')

    log "Updated PR Queue: $pr_queue" "DEBUG"
    
    log "Adding: $deployed_path to associated Deployed Array" "DEBUG"
    pr_queue=$( echo $pr_queue | jq \
        --arg deployed_path "$deployed_path" '
        ($deployed_path | fromjson) as $deployed_path
        | (.InProgress.CommitStack.InProgress.RollbackPaths) |=  [$deployed_path]
    ')

    echo "$pr_queue"
}

is_commit_stack_empty() {
    local pr_queue=$1
    local commit_order_id=$2
    
    bool=$( echo $pr_queue | jq '
        if .InProgress.CommitStack.InProgress.DeployStack == {} 
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

pr_to_front() {
    local pr_queue=$1
    local pull_request_id=$2
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    echo "$( echo $pr_queue | jq \
        --arg pull_request_id "$pull_request_id" '
        (.Queue | map(.ID == $pull_request_id) | index(true)) as $idx
        | .Queue |= [.[$idx]] + (. | del(.[$idx]))
    ')"
}

update_pr_queue_with_next_pr() {
    local pr_queue=$1
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    if [ -z "$pr_queue" ]; then
        log "pr_queue is not defined" "ERROR"
        exit 1
    fi

    log "Moving finished PR to Finished category" "INFO"
    pr_queue=$(echo $pr_queue | jq '.Finished += [.InProgress] | del(.InProgress)')

    log "Moving next PR in Queue to InProgress" "INFO"
    echo "$( echo $pr_queue | jq '.InProgress = .Queue[0] | del(.Queue[0])')"
}

update_pr_queue_with_next_commit() {
    local pr_queue=$1
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    echo "$( echo $pr_queue | jq '
        .InProgress.CommitStack.InProgress = .InProgress.CommitStack.Queue[0] | del(.InProgress.CommitStack.Queue[0])
    ')"
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

    log "Getting Stacks" "INFO"
    account_stacks=$(create_account_stacks "$approval_mapping")
    log "Account Stacks" "DEBUG"
    log "$account_stacks" "DEBUG"
    log "Adding Stacks to PR Queue"  "INFO"
    echo "$( echo "$pr_queue" | jq \
        --arg account_stacks "$account_stacks" \
        --arg base_source_version "$base_source_version" \
        --arg head_source_version "$head_source_version" '
        ($account_stacks | fromjson) as $account_stacks
        | (.InProgress.CommitStack.InProgress) |= . + {
            "DeployStack": $account_stacks,
            "BaseSourceVersion": $base_source_version,
            "HeadSourceVersion": $head_source_version
        }
        '
    )"
}

update_pr_queue_with_rollback_stack() {
    local pr_queue=$1

    log "Filtering out Terragrunt paths that don't need to be rolled back" "DEBUG"
    #TODO: Select paths that are succed or failed and then convert to waiting phase
    echo "$(echo $pr_queue | jq '
        .InProgress.CommitStack.InProgress.RollbackStack = ((.InProgress.CommitStack.InProgress.DeployStack) 
            | walk( if type == "object" and .Status? then .Status = "Waiting" else . end))
    ')"
}

deploy_stack_in_progress() {
    local pr_queue=$1
    
    echo "$( echo $pr_queue | jq '
        (["SUCCESS", "FAILURE"]) as $finished_status
        | .InProgress.CommitStack.InProgress.DeployStack | [.. | .Status? | strings] | unique | map(. | IN($finished_status[])) | all | not
    ')"
}

needs_rollback() {
    local pr_queue=$1
    
    echo "$( echo $pr_queue | jq '
        (["FAILURE"]) as $failure_status
        | .InProgress.CommitStack.InProgress.DeployStack | [.. | .Status? | strings] | unique | map(. | IN($failure_status[])) | any
    ')"
}

commit_queue_is_empty() {
    local pr_queue=$1
    
    echo "$( echo $pr_queue | jq '
        .InProgress.CommitStack.Queue | length == 0
    ')"
}

trigger_sf() {
    set -e
    log "Getting PR queue" "INFO"
    pr_queue=$(get_pr_queue)
    
    if [ "$CODEBUILD_INITIATOR" == "$EVENTBRIDGE_RULE" ]; then
        log "Triggered via Step Function Event" "INFO"
        
        sf_event=$( echo $EVENTBRIDGE_EVENT | jq '. | fromjson')
        deployed_path=$( echo $sf_event | jq '.Path')

        log "Step Function Event:" "DEBUG"
        log "$sf_event" "DEBUG"

        pr_queue=$( update_pr_queue_with_deployed_path "$pr_queue" "$deployed_path")
        log "Updated PR Queue:" "DEBUG"
        log "$pr_queue" "DEBUG"

    fi

    if [ "$CODEBUILD_INITIATOR" == "user" ]; then
        if [ -n "$NEXT_PR_IN_QUEUE" ]; then
            log "Moving PR: $NEXT_PR_IN_QUEUE to front of Pull Request Queue" "INFO"
            pr_queue=$(pr_to_front "$NEXT_PR_IN_QUEUE")
            log "Updated Pull Request Queue:" "INFO"
            log "$(echo $pr_queue | jq '.Queue')" "INFO"
            exit 0
        else
            log "Env Var: NEXT_PR_IN_QUEUE is not defined" "ERROR"
            exit 1
        fi

        if [ -n "$RELEASE_CHANGE" ]; then
            log "Updating Commit Queue to only include most recent commit" "INFO"
            pr_queue=$(release_commit_change "$pr_queue")
            log "Updated Commit Queue:" "DEBUG"
            log "$(echo $pr_queue | jq '.InProgress.CommitStack.Queue')" "DEBUG"

            if rollback_stack_in_progress "$pr_queue"; then
                log "Release change is not available when rollback is in progress" "ERROR"
                log "Once rollback is done, the current most recent commit will be next" "ERROR"
                exit 1
            else
                log "Stopping Step Function executions that are running" "INFO"
                stop_running_sf_executions
                log "Removing all commits in queue except most recent commit" "INFO"
        fi
    fi
    
    if [ $(deploy_stack_in_progress "$pr_queue") == false ] && if [ $(rollback_in_progress) == false ]; then
        log "No Deployment or Rollback stack is in Progress" "DEBUG"
        if [ $(needs_rollback) == true ]; then
            log "Adding Rollback Stack" "INFO"
            pr_queue=$(update_pr_queue_with_rollback_stack $pr_queue)
            target_stack=$( echo $pr_queue | jq '
                .InProgress.CommitStack.InProgress.RollbackStack
            ')
        else
            if [ $(commit_queue_is_empty) == true ] ; then
                log "Pulling next Pull Request from PR queue" "INFO"
                pr_queue=$(update_pr_queue_with_next_pr "$pr_queue")
            fi

            log "Pulling next Commit from queue" "INFO"
            pr_queue=$(update_pr_queue_with_next_commit "$pr_queue")

            log "Checking out target commit" "INFO"
            commit_id=$(echo $pr_queue | jq '.InProgress.CommitStack.InProgress.ID')
            log "Commit ID: $commit_id" "DEBUG"
            git checkout "$commit_id"

            log "Creating commits deployment stack"
            pr_queue=$(update_pr_queue_with_new_commit_stack "$pr_queue")

            log "Updated PR Queue:" "INFO"
            log "$pr_queue" "DEBUG"

            target_stack=$( echo $pr_queue | jq '.InProgress.CommitStack.InProgress.DeployStack')
        fi
    fi

    log "Target Stack" "DEBUG"
    log "$target_stack" "DEBUG"

    target_paths=$(get_target_paths "$target_stack")
    log "Target Paths:" "DEBUG"
    log "$target_paths" "DEBUG"

    log "Starting Step Function Deployment Flow" "INFO"
    start_sf_executions $target_paths

    log "Uploading Updated PR Queue" "INFO"
    upload_pr_queue $pr_queue
}


#TODO: 
# - Fix template repo dir structure for global/ - put outside us-west-2
    
# Once deploy/rollback stack is successful and commit queue is empty, then run next PR in Queue
# Once account stack deps are sucessful, run account stack
# Once path stack deps are successful, run path

# Once all paths are done (to make sure there are no in progress tf applies that fails are left unnoticed), allow rollback stack
# Create rollback stack with paths that are successful/failed and add previous commit stack to queue
# Once rollback stack is all successful, get next from queue
# Once queue is done, get next PR

# - Add SF execution ARN to Stack Path artifact for task status lookup


# User:
#     - Set PR
#     - Release Changes


# Idea #1
# if path fails/rejected, delete new providers or delete new file for commit 
# continue process for previous commit
# when previous commit == base ref, apply all on base commit

# Idea #2
# if path fails/rejected, delete new providers or delete new file for commit 
# apply all on base commit
# doesn't allow for partial apply for commits



#TOMORROW:
#Process
# - If a path fails, tf destroy for all paths that have new providers/file
# - Get previous commit from finished and repeat tf destroy process
# - If previous commit == base, tf apply all on base

#TODO:
# - Add tests for destroy flags
# - apply sf definition