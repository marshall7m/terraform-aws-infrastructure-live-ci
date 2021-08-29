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
    
    parsed_stack=$(jq -n '[]')
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
                . + [{
                    "path": $parent,
                    "dependencies": try ($deps | split("\n") | reverse) // []' 
                }]
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
            | map(select(.path | IN($filter[])))
            | map(.dependencies |= map_values(select(. | IN($filter[]))))
        '
    )
}

update_stack_with_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local stack=$1
    local -n target_paths=$2

    for dir in "${target_paths[@]}"; do
        new_providers=$(get_new_providers "$dir")

        stack=$(echo $stack | jq \
        --arg dir $dir \
        --arg new_providers $new_providers '
        map( if .path == $dir then .new_providers == $new_providers else . end)
        ')
    done
    
    echo "$stack"
}

create_stack() {
    local terragrunt_working_dir=$1
    local git_root=$2
    
    #  --arg base_source_version "$base_source_version" \
    #         --arg head_source_version "$head_source_version"
    tg_plan_out=$(get_tg_plan_out $terragrunt_working_dir)
    exitcode=$?
    if [ $exitcode -eq 1 ]; then
        log "Error running terragrunt commmand" "ERROR"
        log "Command Output:" "ERROR"
        log "$tg_plan_out" "ERROR"
        exit 1
    fi
    diff_paths=($(get_diff_paths "$tg_plan_out" "$gti_root"))
    log "Terragrunt Paths with Detected Difference: $(printf "\n\t%s" "${diff_paths[@]}")" "DEBUG"

    num_diff_paths="${#diff_paths[@]}"
    log "Count: $num_diff_paths" "DEBUG"

    stack=$(get_parsed_stack "$tg_plan_out" "$git_root")
    log "Terragrunt Dependency Stack: $stack" "DEBUG"

    log "Filtering out Terragrunt paths with no difference in plan" "DEBUG"
    stack=$( filter_paths "$stack" "${diff_paths[*]}" )
    
    log "Getting New Providers within Stack" "DEBUG"
    stack=$(update_stack_with_new_providers "$stack" "$diff_paths")

    echo "$stack"
}

get_target_stack() {
    local executions=$2
    local commit_id=$2

    log "Getting list of accounts that have no account dependencies or no account dependencies that waiting or running" "DEBUG"
    target_accounts=$( echo $executions | jq \
    --arg commit_id $commit_id '
        map(select(.commit_id == $commit_id))
        | group_by(.account_name) 
        | map(select([.[] | .status == "SUCCESS"] | all) | .[] | .account_name) 
        | unique
    ')

    log "Getting Deployment Paths from Accounts:" "INFO"
    log "$target_accounts" "DEBUG"

    log "Getting executions that have their dependencies finished" "DEBUG"
    echo "$( echo $executions | jq \
        --arg target_accounts "$target_accounts" \
        --arg commit_id "$commit_id" '
        ($target_accounts | fromjson) as $target_accounts
        | map(select(.account_name | IN($target_accounts[]) and .commit_id == $commit_id))
        | (map(select(.status | IN("SUCCESS")) | .path)) as $successful_paths
        | map(select(.status == "WAITING" and [.dependencies | .[] | IN($successful_paths[]) or . == null] | all ))
    ')"
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

start_sf_executions() {
    local target_stack=$1
    readarray -t target_paths < <(echo $target_stack | jq -c '[keys]')

    for dir in "${target_paths[@]}"; do
        sf_input=$(echo $target_stack | jq \
        --arg dir $dir '
            .[$dir] | tojson
        ')

        execution_name="run-$(uuidgen)"
        
        aws stepfunctions start-execution \
            --state-machine-arn $STATE_MACHINE_ARN \
            --name "$execution_name" \
            --input "$sf_input"
    done
}

get_git_source_versions() {
    local pull_request_id=$1
    local base_ref=$2
    local head_ref=$3

    base_source_version=refs/heads/$BASE_REF^{$( git rev-parse --verify $BASE_REF )}
    head_source_version=refs/pull/$pull_request_id/head^{$commit_id}
}
validate_execution() {
    #types: numbers, strings, booleans, arrays, objects 
    rules=$(jq -n '
    {
        "execution_id": {
            "type": "strings"
            "regex_value": ".+"
        },
    }
    ')
}

update_execution_status() {
    local executions=$1
    local execution_id=$2
    local status=$3
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    is_valid_status "$status"
    echo "$(echo $executions | jq \
        --arg execution_id "$execution_id" \
        --arg status $status '
        map(if .execution_id == $execution_id then .status |= $status else . end)
    ')"
}

pr_to_front() {
    local executions=$1
    local pull_request_id=$2
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    echo "$( echo $executions | jq \
        --arg pull_request_id "$pull_request_id" '
        (.Queue | map(.ID == $pull_request_id) | index(true)) as $idx
        | .Queue |= [.[$idx]] + (. | del(.[$idx]))
    ')"
}

update_executions_with_new_deploy_stack() {
    set -e
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local executions=$1
    local account_dim=$2
    local commit_item=$3
    
    log "Creating new Deployment Stack" "INFO"
    
    get_git_source_versions $pull_request_id
    log "Base Ref Source Version: $base_source_version" "DEBUG"
    log "Head Ref Source Version: $head_source_version" "DEBUG"

    log "Getting Stacks" "INFO"
    # gets absolute path to the root of git repo
    git_root=$(get_git_root)
    log "Git Root: $git_root" "DEBUG"
    
    readarray -t account_paths < <(echo $account_dim | jq 'map(.account_path)' | jq -c '.[]')
    for account_path in "${account_paths[@]}"; do
        log "Getting Stack for path: $account_path" "DEBUG"
        stack="$(create_stack $account_path $git_root)" || exit 1
        
        log "Stack:" "DEBUG"
        log "$stack" "DEBUG"

        log "Adding account artifact" "DEBUG"
        executions=$( echo "$executions" | jq \
            --arg name $name \
            --arg stack "$stack"
            --arg account_dim "$account_dim" \
            --arg account_path "$account_path" '
            ($stack | fromjson) as $stack
            | ($commit_item | fromjson) as $commit_item
            | ($account_dim | fromjson | map(select(.account_path == $account_path))) as $account_dim
            | . + [ ($stack | map($account_dim + $commit_item + .)) ]'
        )
    done

    echo "$executions"
}

update_executions_with_new_rollback_stack() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local executions=$1
    local commit_id=$2

    echo "$(echo "$executions" | jq \
        --arg commit_id $commit_id '
        (.) as executions
        | map(select(.commit_id == $commit_id and .new_resources | length > 0 )) as $commit_executions
        | $commit_executions 
        | map( (.) as $item | $item.dependencies | map($item + {"path": (.), "dependencies": [$item.path]}))
        | map((.new_resources | map("-target " + .) | join(" ")) as $destroy_flags 
        | . + {
            "status": "WAITING"
            "plan_command": "destroy $target_flags",
            "deploy_command": "destroy $target_flags -auto-approve"
        })
    ')"
}

get_tg_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local terragrunt_working_dir=$1
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    terragrunt providers \
        --terragrunt-working-dir $terragrunt_working_dir 
}

get_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local terragrunt_working_dir=$1
    log "Running Terragrunt Providers Command" "INFO"
    tg_providers_cmd_out=$(get_tg_providers "$terragrunt_working_dir")
    log "Terragrunt Command Output" "DEBUG"
    log "$tg_providers_cmd_out" "DEBUG"

    log "Getting Terragrunt file providers" "INFO"
    cfg_providers=$(echo "$tg_providers_cmd_out" | grep -oP '─\sprovider\[\K.+(?=\])' | sort -u)
    log "Providers: $(printf "\n%s" "${cfg_providers[@]}")" "DEBUG"

    log "Getting Terragrunt state providers" "INFO"
    state_providers=$(echo "$tg_providers_cmd_out" | grep -oP '^\s+provider\[\K.+(?=\])' | sort -u)
    log "Providers: $(printf "\n%s" "${state_providers[@]}")" "DEBUG"

    log "Getting providers that are not in the state file" "INFO"
    new_providers=()
    while read -r provider; do
        log "Provider: $provider" "DEBUG"
        if [[ ! " ${state_providers[@]} " =~ " ${provider} " ]]; then
            log "Status: NEW" "DEBUG"
            new_providers+="${provider}"
        else
            log "Status: ALREADY EXISTS" "DEBUG"
        fi
    done <<< "$cfg_providers"

    echo "$new_providers"
}

update_execution_with_new_resources() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local executions=$1
    local execution_id=$2
    local terragrunt_working_dir=$2

    new_providers=$(echo $executions | jq \
        --arg execution_id $execution_id '
            map(select(.execution_id == $execution_id))[0] | .new_providers
    ')

    log "Execution's New Providers:" "DEBUG"
    log "${new_providers[*]}" "DEBUG"

    new_resources=$(get_new_providers_resources "$terragrunt_working_dir" "${new_providers[*]}")

    if [ "${#new_resources}" != 0 ]; then
        log "Resources from new providers:" "INFO"
        echo "${new_resources[*]}" "INFO"
    else
        log "No new resources from new providers were detected" "INFO"
        exit 0
    fi

    echo "$(echo $executions | jq \
        --arg execution_id "$execution_id" \
        --arg new_resources "$new_resources" '
        ($new_resources | fromjson) as $new_resources
        | map(if .execution_id == $execution_id then .new_resources |= $new_resources else . end)
    ')"
}

get_tg_state() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local terragrunt_working_dir=$1

    terragrunt state pull \
        --terragrunt-working-dir $terragrunt_working_dir 
}

get_new_providers_resources() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local terragrunt_working_dir=$1

    #input must be expanded bash array (e.g. "${x[*]}")
    local new_providers=$2

    tg_state_cmd_out=$(get_tg_state "$terragrunt_working_dir")
    log "Terragrunt State Output:" "DEBUG"
    log "$tg_state_cmd_out" "DEBUG"

    #TODO: Create jq filter to remove external jq_regex with test()
    jq_regex=$(echo $new_providers | tr '\n(?!$)' '|' | sed '$s/|$//')
    new_resources=$(echo $tg_state_cmd_out | jq -r \
        --arg NEW_PROVIDERS "$jq_regex" \
        '.resources | map(select( (.provider | test($NEW_PROVIDERS) == true) and .mode != "data" ) | {type, name} | join(".")) ')
    
    echo "$new_resources"
}

verify_param() {
    if [ -z "$1" ]; then
        log "No arguments supplied" "ERROR"
        exit 1
    else
        echo "$1"
    fi
}

executions_in_progress() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local executions=$1

    if [[ "$(echo $executions | jq 'map(select(.status == "RUNNING")) | length > 0')" == true ]]; then
        return 0
    else
        return 1
    fi
}

execution_finished() {
    set -e
    local executions=$1
    local commit_queue=$2

    log "Triggered via Step Function Event" "INFO"

    var_exists "$EVENTBRIDGE_EVENT"
    sf_event=$( echo $EVENTBRIDGE_EVENT | jq '. | fromjson')
    log "Step Function Event:" "DEBUG"
    log "$sf_event" "DEBUG"

    deployed_path=$( echo $sf_event | jq '.path')
    execution_id=$( echo $sf_event | jq '.execution_id')
    deployment_type=$( echo $sf_event | jq '.deployment_type')
    status=$( echo $sf_event | jq '.status')
    
    log "Updating Execution Status" "INFO"
    executions=$( update_execution_status "$executions" "$execution_id" "$status" )

    if [ "$deployment_type" == "Deploy" ]; then
        git checkout "$commit_id"
        executions=$( update_execution_with_new_resources "$executions" "$deployed_path") 
        if [ "$status" == "Failed" ]; then
            commit_queue=$(update_commit_queue_with_rollback_commits "$commit_queue" "$executions" "$commit_id")
            log "Commit Queue:" "DEBUG"
            log "$commit_queue" "DEBUG"
        fi
    fi

    log "Updated Executions Table:" "DEBUG"
    log "$executions" "DEBUG"
}

update_commit_queue_with_rollback_commits() {
    local commit_queue=$1
    local executions=$2
    local pr_id=$3

    rollback_commit_items="$(echo "$executions" | jq \
    --arg pr_id "$pr_id" \
    --arg commit_queue "$commit_queue" '
    ($commit_queue | fromjson) as $commit_queue
    | ($pr_id | tonumber) as $pr_id
    | (map(select(
        .pr_id == $pr_id and 
        .type == "Deploy" and
        (.new_resources | length > 0)
    ))
    | map(.commit_id) | unique) as $rollback_commits
    | $commit_queue 
    | map(select(
        (.type == "Deploy") and
        (.commit_id | IN($rollback_commits[]))
    ))
    | map(.type = "Rollback" | .status = "Waiting")
    ')"

    log "Rollback commit items:" "DEBUG"
    log "$rollback_commit_items" "DEBUG"

    log "Adding rollback commit items to front of commit queue" "DEBUG"
    echo "$(echo "$commit_queue" | jq \
    --arg rollback_commit_items "$rollback_commit_items" '
        ($rollback_commit_items | fromjson) as $rollback_commit_items
        | $rollback_commit_items + .
    ')"
}

dequeue_commit_from_commit_queue() {
    local commit_queue=$1

    echo "$commit_queue" | jq '
        (map(select(.status == "Waiting"))[0].commit_id) as $target
        | map(if .commit_id == $target then .status = "Running" else . end)
    '
}

create_executions() {
    local executions=$1
    local commit_queue=$2

    log "No Deployment or Rollback stack is in Progress" "DEBUG"

    commit_queue=$(dequeue_commit_from_commit_queue "$commit_queue")
    commit_item=$(echo "$commit_queue" | jq 'map(select(.status == "Running"))')
    deployment_type=$(echo "$commit_item" | jq '.type')
    commit_id=$(echo "$commit_item" | jq '.commit_id')

    if ["$deployment_type" == "Deploy"]; then
        executions=$(update_executions_with_new_deploy_stack "$executions" "$account_dim" "$commit_item")
    elif ["$deployment_type" == "Rollback"]; then
        executions=$(update_executions_with_new_rollback_stack "$executions")
    fi
}

get_build_artifacts() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    executions=$(get_artifact "$ARTIFACT_BUCKET_NAME" "$EXECUTION_QUEUE_S3_KEY")
    commit_queue=$(get_artifact "$ARTIFACT_BUCKET_NAME" "$commit_queue_S3_KEY")
    account_dim=$(get_artifact "$ARTIFACT_BUCKET_NAME" "$ACCOUNT_DIM_S3_KEY")
}

main() {
    set -e

    check_for_env_var "$CODEBUILD_INITIATOR"
    check_for_env_var "$EVENTBRIDGE_FINISHED_RULE"
    check_for_env_var "$ARTIFACT_BUCKET_NAME"
    check_for_env_var "$EXECUTION_QUEUE_S3_KEY"
    check_for_env_var "$EXECUTION_QUEUE_S3_KEY"
    check_for_env_var "$ACCOUNT_QUEUE_S3_KEY"

    #TODO: Add env vars for each *_S3_KEY
    log "Getting S3 Artifacts" "INFO"
    get_build_artifacts
    
    log "Checking if build was triggered via a finished Step Function execution" "DEBUG"
    if [ "$CODEBUILD_INITIATOR" == "$EVENTBRIDGE_FINISHED_RULE" ]; then
        execution_finished "$execution" "$commit_queue"
    fi

    log "Checking if any Step Function executions are running" "DEBUG"
    if [ $(executions_in_progress "$executions") == false ]; then
        create_executions "$execution" "$commit_queue"
    fi

    log "Getting Target Executions" "INFO"
    target_stack=$(get_target_stack "$account_dim" "$commit_queue" "$commit_id")
    log "Target Executions" "DEBUG"
    log "$target_stack" "DEBUG"

    log "Starting Step Function Deployment Flow" "INFO"
    start_sf_executions "$target_stack"

    log "Uploading Updated PR Queue" "INFO"
    upload_executions $executions
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi