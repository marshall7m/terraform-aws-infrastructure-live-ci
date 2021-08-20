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

update_stack_with_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local stack=$1
    local -n target_paths=$2

    for dir in "${target_paths[@]}":
        new_providers=$(get_new_providers "$dir")

        stack=$(echo $stack | jq \
        --arg dir $dir \
        --arg new_providers $new_providers '
        .[$dir].NewProviders = $new_providers
        ')
    done
    
    echo "$stack"
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
    
    log "Getting New Providers within Stack" "DEBUG"
    stack=$(update_stack_with_new_providers "$stack" "$diff_paths")

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
        | .value.Path as $path 
        | .key + "=" + $path'
    )

    log "Accounts: $( typeset -p accounts )" "DEBUG"

    # gets absolute path to the root of git repo
    git_root=$(get_git_root)
    log "Git Root: $git_root" "DEBUG"
    
    for name in "${!accounts[@]}"; do
        name=$( echo "${name}" | tr -d '"' )
        log "Name: $name" "DEBUG"

        parent_path="${accounts[$name]}"
        log "Parent Path:" "DEBUG"
        log "$parent_path" "DEBUG"

        log "Getting Stack for path: $parent_path" "DEBUG"
        stack="$(create_stack $parent_path $git_root)" || exit 1
        
        log "Stack:" "DEBUG"
        log "$stack" "DEBUG"

        log "Adding account artifact" "DEBUG"
        account_stacks=$( echo "$approval_mapping" | jq \
            --arg name $name \
            --arg stack "$stack" '
            ($stack | fromjson) as $stack
            | .[$name] |= . + {
                "Status": "Waiting",
                "Stack": $stack
            }'
        )
    done

    echo "$account_stacks"
}

get_target_stack() {
    local stack=$1

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
        | [.[] | (.Stack) as $stack | $stack | to_entries[] | select(.value.Status == "WAITING" and (.value.Dependencies | map($stack[.].Status == "SUCCESS" or . == null ) | all) )]
    ')"

}

checkout_in_progress_commit() {
    local pr_queue=$1
    
    commit_id=$(echo $pr_queue | jq '.InProgress.CommitStack.InProgress.ID')
    log "Commit ID: $commit_id" "DEBUG"
    git checkout "$commit_id"
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

    approval_mapping=$(echo $pr_queue | .ApprovalMapping)
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

#!/bin/bash

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
source "$DIR/utils.sh"

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

add_new_resources() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1
    local new_resources=$2

    check_build_env_vars

    echo "$( echo $pr_queue | jq \
    --arg account $ACCOUNT \
    --arg path $TARGET_PATH \
    --arg new_resources "$new_resources" '
        (try ($new_resources | split(" ")) // []) as $new_resources
            | .InProgress.CommitStack.InProgress.DeployStack[$account].Stack[$path].NewProviderResources = $new_resources
    ')"
}


update_pr_queue_with_new_resources() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1
    local terragrunt_working_dir=$2

    new_providers=$(echo $pr_queue | jq \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH '
            .InProgress.CommitStack.InProgress.DeployStack[$account].Stack[$path].NewProviders
    ')

    new_resources=$(get_new_providers_resources "$terragrunt_working_dir" "${new_providers[*]}")

    if [ "${#new_resources}" != 0 ]; then
        log "Resources from new providers:" "INFO"
        echo "${new_resources[*]}" "INFO"
    else
        log "No new resources from new providers were detected" "INFO"
        exit 0
    fi

    pr_queue=$(add_new_resources "$pr_queue" "${new_resources[*]}")
    log "Updated PR Queue:" "DEBUG"
    log "$pr_queue" "DEBUG"

    upload_pr_queue "$pr_queue"
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

update_pr_queue_with_destroy_targets_flags() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1

    check_build_env_vars

    new_resources=$(echo $pr_queue | jq \
    --arg account $ACCOUNT \
    --arg path $TARGET_PATH '
        .InProgress.CommitStack.InProgress.DeployStack[$account].Stack[$path].NewProviderResources
    ')

    flags=$(create_destroy_target_flags "${new_resources[*]}")

    pr_queue=$(echo $pr_queue | jq \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH \
        --arg flags $flags '
            .InProgress.CommitStack.InProgress.DeployStack[$account].Stack[$path].NewProviderResourcesTargetFlags = $flags
    ')

    log "Updated PR Queue:" "DEBUG"
    log "$pr_queue" "DEBUG"

    upload_pr_queue "$pr_queue"
}

read_destroy_targets_flags() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1

    check_build_env_vars

    echo "$(echo $pr_queue | jq \
        --arg account $ACCOUNT \
        --arg path $TARGET_PATH \
        --arg flags $flags '
            .InProgress.CommitStack.InProgress.DeployStack[$account].Stack[$path].NewProviderResourcesTargetFlags
    ')"
}

main() {
    set -e
    log "Getting PR queue" "INFO"
    pr_queue=$(get_pr_queue)
    
    if [ "$CODEBUILD_INITIATOR" == "$EVENTBRIDGE_RULE" ]; then
        log "Triggered via Step Function Event" "INFO"
        
        sf_event=$( echo $EVENTBRIDGE_EVENT | jq '. | fromjson')
        deployed_path=$( echo $sf_event | jq '.Path')

        log "Step Function Event:" "DEBUG"
        log "$sf_event" "DEBUG"

        checkout_in_progress_commit "$pr_queue"
        pr_queue=$( update_pr_queue_with_deployed_path "$pr_queue" "$deployed_path" | update_pr_queue_with_new_resources "$pr_queue" "$deployed_path")

        log "Updated PR Queue:" "DEBUG"
        log "$pr_queue" "DEBUG"

        stack=$( echo $pr_queue | jq '.InProgress.CommitStack.InProgress.DeployStack')
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

    if [ $(deploy_stack_in_progress "$pr_queue") == true ] 
        stack=$( echo $pr_queue | jq '.InProgress.CommitStack.InProgress.DeployStack')
    elif [ $(rollback_in_progress) == true ]; then
        stack=$( echo $pr_queue | jq '.InProgress.CommitStack.InProgress.RollbackStack')
    elif [ $(needs_rollback) == true ]; then
            log "No Deployment or Rollback stack is in Progress" "DEBUG"
            log "Adding Rollback Stack" "INFO"

            pr_queue=$(update_pr_queue_with_rollback_stack $pr_queue)
            stack=$( echo $pr_queue | jq '.InProgress.CommitStack.InProgress.RollbackStack')
    else
        if [ $(commit_queue_is_empty) == true ] ; then
            log "Pulling next Pull Request from PR queue" "INFO"
            pr_queue=$(update_pr_queue_with_next_pr "$pr_queue")
        fi

        log "Pulling next Commit from queue" "INFO"
        pr_queue=$(update_pr_queue_with_next_commit "$pr_queue")

        log "Checking out target commit" "INFO"
        checkout_in_progress_commit "$pr_queue"

        log "Creating commits deployment stack"
        pr_queue=$(update_pr_queue_with_new_commit_stack "$pr_queue")

        log "Updated PR Queue:" "INFO"
        log "$pr_queue" "DEBUG"

        stack=$( echo $pr_queue | jq '.InProgress.CommitStack.InProgress.DeployStack')  
    fi

    target_stack=$(get_target_stack "$stack")
    log "Target Stack" "DEBUG"
    log "$target_stack" "DEBUG"

    log "Starting Step Function Deployment Flow" "INFO"
    start_sf_executions "$target_stack"

    log "Uploading Updated PR Queue" "INFO"
    upload_pr_queue $pr_queue
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi