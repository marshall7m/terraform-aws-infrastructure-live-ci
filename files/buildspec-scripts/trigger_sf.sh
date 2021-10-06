#!/bin/bash

source "$( cd "$( dirname "$BASH_SOURCE[0]" )" && cd "$(git rev-parse --show-toplevel)" >/dev/null 2>&1 && pwd )/node_modules/bash-utils/load.bash"
export SQL_DIR="$( cd "$( dirname "$BASH_SOURCE[0]" )/sql"  >/dev/null 2>&1 && pwd )"
# find "$src_path" -type f -exec chmod u+x {} \;

get_diff_paths() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local tg_plan_out=$1
    local git_root=$2
    
    # use pcregrep with -M multiline option to scan terragrunt plan output for
    # directories that exited plan with exit status 2 (diff in plan)
    # -N flag defines the convention for newline and CRLF allows for all of the conventions
    abs_paths=($( echo "$tg_plan_out" \
        | pcregrep -Mo -N CRLF '(?<=exit\sstatus\s2\n).+?(?=\])' \
        | grep -oP 'prefix=\[\K.+'
    ))
    log "Absolute paths: $(printf '\n\t%s\n' "${abs_paths[@]}")" "DEBUG"

    diff_paths=()

    for dir in "${abs_path[@]}"; do
        diff_paths+=($(realpath -e --relative-to="$git_root" "$dir"))
    done
}

get_parsed_stack() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local tg_plan_out=$1
    local git_root=$2

    raw_stack=$( echo $tg_plan_out | grep -oP '=>\sModule\K.+?(?=\))' )

    log "Raw Stack:" "DEBUG"
    log "${raw_stack[*]}" "DEBUG"
    
    parsed_stack=$(jq -n '[]')
    while read -r line; do
        log "" "DEBUG"
        log "Stack Layer: $(printf "\n\t%s\n" "$line")" "DEBUG"

        abs_parent=$( echo "$line" | grep -Po '\s?\K.+?(?=\s\(excluded:)')
        log "Absolute path to parent $(printf "\n\t%s\n" "${abs_parent[@]}")" "DEBUG"

        while read -r dir; do
            parent=$(realpath -e --relative-to="$git_root" "$dir")
        done <<< "$abs_parent"

        log "Parent: $(printf "\n\t%s\n" "${parent}")" "DEBUG"

        if [ -z "$parent" ]; then
            log "Parent directory was not properly detected -- Terragrunt stack output for current Terragrunt version is not supported" "ERROR"
            exit 1
        fi

        abs_deps=$(echo "$line" | grep -Po 'dependencies:\s+\[\K.+?(?=\])' | grep -Po '\/.+?(?=,|$)')
        log "Absolute paths to dependencies $(printf "\n\t%s\n" "${abs_deps[@]}")" "DEBUG"
        deps=()
        while read -r dir; do
            if [ "$dir" != "" ]; then
                deps+=($( echo "$dir" | realpath -e --relative-to="$git_root" "$dir"))
            fi
        done <<< "$abs_deps"

        log "Dependencies: $(printf "\n\t%s" "${deps[@]}")" "DEBUG"
        
        parsed_stack=$( echo $parsed_stack \
            | jq --arg parent "$parent" --arg deps "$deps" '
                . + [{
                    "cfg_path": $parent,
                    "cfg_deps": $deps | split("\n") | reverse
                }]'
        )
    done <<< "$raw_stack"

    echo "$parsed_stack"
}

filter_paths() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local stack=$1
    #input must be expanded bash array (e.g. "${x[*]}")
    local filter=$2

    echo "$( echo "$stack" | jq \
        --arg filter "$filter" '
        ($filter | split("\n")) as $filter
            | map(select(.cfg_path | IN($filter[])))
            | map(.cfg_deps |= map_values(select(. | IN($filter[]))))
        '
    )"
}

update_stack_with_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local stack=$1
    
    while read dir; do
        dir=$(echo "$dir" | tr -d '"')
        log "Directory: $dir" "DEBUG"
        get_new_providers "$dir"

        stack=$(echo "$stack" | jq \
        --arg dir "$dir" \
        --arg new_providers "${new_providers[*]}" '
        (if $new_providers == null or $new_providers == "" then [] else ($new_providers | split(" ")) end) as $new_providers
        | map(if .cfg_path == $dir then .new_providers |= $new_providers else . end)
        ')
    done <<< "$(echo "$stack" | jq 'map(.cfg_path)' | jq -c '.[]')"
    
    echo "$stack"
}

create_stack() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local terragrunt_working_dir=$1
    local git_root=$2

    # returns the exitcode instead of the plan output (0=no plan difference, 1=error, 2=detected plan difference)
    tg_plan_out=$(terragrunt run-all plan \
        --terragrunt-working-dir $terragrunt_working_dir \
        --terragrunt-non-interactive \
        -detailed-exitcode 2>&1
    )

    exitcode=$?
    if [ $exitcode -eq 1 ]; then
        log "Error running terragrunt commmand" "ERROR"
        log "Command Output:" "ERROR"
        log "$tg_plan_out" "ERROR"
        exit 1
    fi

    get_diff_paths "$tg_plan_out" "$git_root"

    num_diff_paths=${#diff_paths[@]}

    log "Terragrunt paths with detected difference: $(printf '\n\t%s' "${diff_paths[@]}")" "DEBUG"
    log "Count: $num_diff_paths" "DEBUG"
    
    if [ $num_diff_paths -eq 0 ]; then
        log "Detected no Terragrunt paths with difference" "INFO"
        exit 0
    fi

    stack="$(get_parsed_stack "$tg_plan_out" "$git_root")" || exit 1
    log "Terragrunt Dependency Stack:" "DEBUG"
    log "$stack" "DEBUG"

    log "Filtering out Terragrunt paths with no difference in plan" "INFO"
    stack=$( filter_paths "$stack" "${diff_paths[*]}" )
    log "Filtered out:" "DEBUG"
    log "$stack" "DEBUG"

    log "Getting New Providers within Stack" "INFO"
    stack=$(update_stack_with_new_providers "$stack")

    echo "$stack"
}

update_executions_with_new_deploy_stack() {
    set -e
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local commit_id=$1
    
    if [ -z "$BASE_REF" ]; then
        log "BASE_REF is not set" "ERROR"
        exit 1
    fi

    log "Getting Account Paths" "INFO"
    IFS=$'\n' account_paths=($(psql -tA -c "SELECT account_path FROM account_dim;"))

    if [ ${#account_paths} -eq 0 ]; then
        log "No account paths are defined in account_dim" "ERROR"
        exit 1
    fi
    
    log "Checking out target commit ID: $commit_id" "INFO"
    git checkout "$commit_id"
    # getting tg dirs relative path to git repo absolute path given tg dir's absolute path will be invalid in other envs
    git_root=$(git rev-parse --show-toplevel)
    log "Git Root: $git_root" "DEBUG"

    log "Getting Account Stacks" "INFO"
    for account_path in "${account_paths[@]}"; do
        log "Account Path: $account_path" "DEBUG"

        stack=$(create_stack $account_path $git_root) || exit 1
        log "Stack: $(printf '\n%s' "$stack")" "DEBUG"

        if [ "$stack" == "" ]; then
            log "Stack is empty -- skipping" "DEBUG"
            continue
        fi

        jq_to_psql_records "$stack" "staging_cfg_stack"

        log "staging_cfg_stack table:" "DEBUG"
        log "$(psql -x -c "SELECT * FROM staging_cfg_stack")" "DEBUG"

        log "Inserting execution items for account:" "INFO"
        psql \
            -v base_ref="'$BASE_REF'" \
            -v base_commit_id "'$( git rev-parse --verify $BASE_REF )'" \
            -v commit_id="'$commit_id'" \
            -v account_path="'$account_path'" \
            -f "$SQL_DIR/update_executions_with_new_deploy_stack.sql"
    done

    log "Cleaning up" "DEBUG"
    psql -c "DROP TABLE IF EXISTS staging_cfg_stack;"
    set +e
}

get_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local terragrunt_working_dir=$1

    log "Running Terragrunt Providers Command" "INFO"
    tg_providers_cmd_out=$( terragrunt providers --terragrunt-working-dir $terragrunt_working_dir 2>&1)
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
            new_providers+=("${provider}")
        else
            log "Status: ALREADY EXISTS" "DEBUG"
        fi
    done <<< "$cfg_providers"
}

update_execution_with_new_resources() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    local execution_id=$1
    local terragrunt_working_dir=$2
    local new_providers=$3

    new_resources=$(get_new_providers_resources "$terragrunt_working_dir" "$new_providers")

    log "Resources from new providers:" "INFO"
    log "$new_resources" "INFO"
    
    psql_new_resources=$(echo "$new_resources" | jq '. | join(" ")' | tr -d '"')

    log "Adding new resources to execution record" "INFO"
    psql -c """
    UPDATE executions
    SET new_resources = string_to_array('$psql_new_resources', ' ')
    WHERE execution_id = '$execution_id'
    ;
    """
}

get_new_providers_resources() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local terragrunt_working_dir=$1
    local new_providers=$2

    tg_state_cmd_out=$(terragrunt state pull --terragrunt-working-dir $terragrunt_working_dir )
    log "Terragrunt State Output:" "DEBUG"
    log "$tg_state_cmd_out" "DEBUG"

    echo "$(echo "$tg_state_cmd_out" | jq -r \
    --arg new_providers "$new_providers" '
        ($new_providers | fromjson) as $new_providers
        | .resources | map(
            select(
                (((.provider | match("(?<=\").+(?=\")").string) | IN($new_providers[]))
                and .mode != "data")
            )
        | {type, name} | join("."))
    ')"
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

    psql -qtAX -c """
    SELECT 
        count(*)
    FROM
        executions
    WHERE
        status = 'running'
    FETCH FIRST ROW ONLY;
    """
}

execution_finished() {
    set -e
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    var_exists "$EVENTBRIDGE_EVENT"
    sf_event=$( echo $EVENTBRIDGE_EVENT | jq '.')
    log "Step Function Event:" "DEBUG"
    log "$sf_event" "DEBUG"

    deployed_path=$( echo $sf_event | jq '.cfg_path' | tr -d '"')
    execution_id=$( echo $sf_event | jq '.execution_id' | tr -d '"')
    is_rollback=$( echo $sf_event | jq '.is_rollback' | tr -d '"')
    status=$( echo $sf_event | jq '.status' | tr -d '"')
    pr_id=$( echo $sf_event | jq '.pr_id' | tr -d '"')
    commit_id=$( echo $sf_event | jq '.commit_id' | tr -d '"')
    new_providers=$( echo $sf_event | jq '.new_providers')
    status=success
    log "Updating Execution Status" "INFO"
    psql -v execution_id="'$execution_id'" -v status="'$status'" -f "$SQL_DIR/cw_event_table_update.sql"
    
    if [ "$is_rollback" == false ]; then
        git checkout "$commit_id" > /dev/null
        if [ "$(echo "$new_providers" | jq '. | length')" -gt 0 ]; then
            log "Config contains new providers" "INFO"
            log "Adding new provider resources to config execution record" "INFO"
            update_execution_with_new_resources "$execution_id" "$deployed_path" "$new_providers"
        fi

        if [ "$status" == "failed" ]; then
            psql -v pr_id="'$pr_id'" -f "$SQL_DIR/update_commit_queue_with_rollback_commits.sql"
        fi
    fi
    set +e
}

create_executions() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    log "Dequeuing next PR if commit queue is empty" "INFO"

    #WA: checking if results is empty till jq handles empty input see: https://github.com/stedolan/jq/issues/1628
    pr_items=$(psql -t -c """
        UPDATE
            pr_queue
        SET
            status = 'running'
        WHERE 
            id = (
                SELECT id
                FROM pr_queue
                WHERE status = 'waiting'
                LIMIT 1
            )
        AND
            0 = (
                SELECT count(*) 
                FROM commit_queue 
                WHERE status = 'waiting'
            )
        RETURNING row_to_json(pr_queue.*);
    """ | jq '.' 2> /dev/null)

    if [ "$pr_items" == "" ]; then
        #TODO: narrow down reason
        log "Another PR is in progress or no PR is waiting" "INFO"
    else
        log "Updating commit queue with dequeued PR's most recent commit" "INFO"

        log "Dequeued pr items:" "DEBUG"
        log "$pr_items" "DEBUG"

        pr_id=$(echo "$pr_items" | jq '.pr_id')
        head_ref=$(echo "$pr_items" | jq '.head_ref')
        
        log "Checking out PR" "DEBUG"
        git fetch origin "pull/$pr_id/head:$head_ref"
        git checkout "$head_ref" || exit 1

        head_commit_id=$(git log --pretty=format:'%H' -n 1)
        
        psql -c """
        INSERT INTO commit_queue (
            commit_id,
            is_rollback,
            pr_id,
            status
        )
        VALUES (
            '$head_commit_id'
            'f'
            '$pr_id'
            'waiting'
        );
        """

        log "Switching back to default branch" "DEBUG"
        git checkout "$(git remote show $(git remote) | sed -n '/HEAD branch/s/.*: //p')" || exit 1
    fi

    log "Dequeuing next commit that is waiting" "INFO"
    commit_items=$(psql -t -c """

    UPDATE
        commit_queue
    SET
        status = 'running'
    WHERE 
        id = (
            SELECT
                id
            FROM
                commit_queue
            WHERE
                status = 'waiting'
            LIMIT 1
        )

    RETURNING row_to_json(commit_queue.*);
    """ | jq '.' 2> /dev/null)
    
    if [ "$commit_items" == "" ]; then
        log "No commits to dequeue -- skipping execution creation" "INFO"
        exit 0
    fi

    log "Dequeued commit items:" "DEBUG"
    log "$commit_items" "DEBUG"

    commit_id=$(echo "$commit_items" | jq '.commit_id' | tr -d '"')
    is_rollback=$(echo "$commit_items" | jq '.is_rollback' | tr -d '"')

    if [ "$is_rollback" == "true" ]; then
        log "Adding commit rollbacks to executions" "INFO"
        psql -v commit_id="'$commit_id'" -f "$SQL_DIR/update_executions_with_new_rollback_stack.sql"
    elif [ "$is_rollback" == "false" ]; then
        log "Adding commit deployments to executions" "INFO"
        update_executions_with_new_deploy_stack "$commit_id"
    else
        log "is_rollback value is invalid" "ERROR"
        exit 1
    fi
}

start_sf_executions() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    log "Getting executions that have all account dependencies and terragrunt dependencies met" "INFO"
    target_execution_ids=$(psql -t -f "$SQL_DIR/select_target_execution_ids.sql" | jq '.' 2> /dev/null)

    log "Target execution IDs:" "INFO"
    log "$target_execution_ids" "INFO"
    
    readarray -t target_execution_ids < <(echo "$target_execution_ids" | jq -c '.[]')

    log "Count: ${#target_execution_ids[@]}" "INFO"

    for id in "${target_execution_ids[@]}"; do
        log "Execution ID: $id" "INFO"

        sf_input=$(psql -t -c """
        SELECT 
            row_to_json(sub) 
        FROM (
            SELECT 
                *
            FROM 
                queued_executions 
            WHERE execution_id = '$id'
        ) sub
        """ | jq -r '. | tojson')
        log "SF input: $(printf '\n\t%s' "$sf_input")" "DEBUG"
        
        if [ -z "$DRY_RUN" ]; then
            log "DRY_RUN is not set -- starting sf executions" "INFO"
            aws stepfunctions start-execution \
                --state-machine-arn "$STATE_MACHINE_ARN" \
                --name "$id" \
                --input "$sf_input"
                
            psql -c """
            UPDATE executions
            SET status = 'running'
            WHERE execution_id = '$id'   
            """
        else
            log "DRY_RUN was set -- skip starting sf executions" "INFO"
        fi
    done
    
    log "Cleaning up" "DEBUG"
    psql -c "DROP TABLE IF EXISTS queued_executions;"
}


stop_running_sf_executions() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    running_executions=$(aws stepfunctions list-executions \
        --state-machine-arn $STATE_MACHINE_ARN \
        --status-filter "running" | jq '.executions | map(.executionArn)'
    )

    for execution in "${running_executions[@]}"; do
        log "Stopping Step Function execution: $execution" "DEBUG"
        aws stepfunctions stop-execution \
            --execution-arn "$execution" \
            --cause "Releasing most recent commit changes"
    done
    
}

main() {
    set -e

    log "FUNCNAME=$FUNCNAME" "DEBUG"

    if [ -z "$CODEBUILD_INITIATOR" ]; then
        log "CODEBUILD_INITIATOR is not set" "ERROR"
        exit 1
    elif [ -z "$EVENTBRIDGE_FINISHED_RULE" ]; then
        log "EVENTBRIDGE_FINISHED_RULE is not set" "ERROR"
        exit 1
    fi
    
    log "Checking if build was triggered via a finished Step Function execution" "DEBUG"
    if [ "$CODEBUILD_INITIATOR" == "$EVENTBRIDGE_FINISHED_RULE" ]; then
        log "Triggered via Step Function Event" "INFO"
        execution_finished
    fi

    log "Checking if any Step Function executions are running" "DEBUG"
    executions_in_progress
    if [ $(executions_in_progress) -eq 0 ]; then
        log "No deployment or rollback executions in progress" "DEBUG"
        create_executions
    fi

    log "Starting Step Function Deployment Flow" "INFO"
    start_sf_executions

    set +e
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi