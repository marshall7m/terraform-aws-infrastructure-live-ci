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
        | grep -oP 'prefix=\[\K.+' && get_rel_path "$git_root"
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
            | grep -Po '.+?(?=\s\(excluded:)' && get_rel_path "$git_root" 
        )
        log "Parent: $(printf "\n\t%s" "${parent}")" "DEBUG"

        deps=($( echo "$line" \
            | grep -Po 'dependencies:\s+\[\K.+?(?=\])' \
            | grep -Po '\/.+?(?=,|$)' && get_rel_path "$git_root"
        ))
        log "Dependencies: $(printf "\n\t%s" "${deps[@]}")" "DEBUG"

        parsed_stack=$( echo $parsed_stack \
            | jq --arg parent "$parent" --arg deps "$deps" '
                . + [{
                    "cfg_path": $parent,
                    "cfg_deps": try ($deps | split("\n") | reverse) // []' 
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
            | map(select(.cfg_path | IN($filter[])))
            | map(.cfg_deps |= map_values(select(. | IN($filter[]))))
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

    diff_paths=($(get_diff_paths "$tg_plan_out" "$git_root"))
    if [ ${#diff_paths[@]} -eq 0 ]; then
        log "Detected no Terragrunt paths with difference" "INFO"
        exit 0
    fi
    
    log "Terragrunt paths with detected difference: $(printf "\n\t%s" "${diff_paths[@]}")" "DEBUG"
    log "Count: $num_diff_paths" "DEBUG"

    stack=$(get_parsed_stack "$tg_plan_out" "$git_root")
    log "Terragrunt Dependency Stack: $stack" "DEBUG"

    log "Filtering out Terragrunt paths with no difference in plan" "INFO"
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
        | map(select([.[] | .status == "success"] | all) | .[] | .account_name) 
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
        | (map(select(.status | IN("success")) | .path)) as $successful_paths
        | map(select(.status == "waiting" and [.dependencies | .[] | IN($successful_paths[]) or . == null] | all ))
    ')"
}

stop_running_sf_executions() {
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
    
    log "Creating new Deployment Stack" "INFO"
    local commit_id=$1
    
    IFS='|' account_paths=($(query --psql-extra-args "-qtA" """
    SELECT
        account_path
    FROM
        account_dim;
    """))

    log "Getting Stacks" "INFO"

    # gets absolute path to the root of git repo
    git_root=$(git rev-parse --show-toplevel)
    log "Git Root: $git_root" "DEBUG"

    for account_path in "${account_paths[@]}"; do
        log "Getting Stack for path: $account_path" "DEBUG"

        stack=$(create_stack $account_path $git_root) || exit 1

        echo "stacKK: $stack"
        if [ "$stack" == "" ]; then
            continue
        fi

        jq_to_psql_records "$stack" "staging_cfg_stack"

        log "staging_cfg_stack table:" "DEBUG"
        log "$(query "-x" "SELECT * FROM staging_cfg_stack")" "DEBUG"

        query """
        UPDATE
            staging_cfg_stack
        SET
            pr_id = pr_id,
            commit_id = commit_id,
            account_path = '$account_path',
            base_source_version = 'refs/heads/$BASE_REF^{$( git rev-parse --verify $BASE_REF )}',
            head_source_version = 'refs/pull/' || pr_id || '/head^{' || commit_id || }'
        FROM (
            SELECT
                pr_id,
                commit_id,
                base_ref,
                head_ref
            FROM
                commit_queue
            WHERE
                commit_id = '$commit_id'
            JOIN (
                SELECT
                    pr_id,
                    base_ref,
                    head_ref
                FROM
                    pr_queue
            )
            ON
                (commit_queue.pr_id = pr_queue.pr_id)
        ) AS sub_commit
        WHERE
            staging_cfg_stack.commit_id = sub_commit.commit_id
        ;
        
        INSERT INTO
            executions
        SELECT
            execution_id,
            false as is_rollback,
            pr_id,
            commit_id,
            cfg_path,
            cfg_deps,
            status,
            plan_command,
            deploy_command,
            new_providers,
            new_resources,
            account_name,
            account_deps,
            account_path,
            voters,
            approval_count,
            min_approval_count,
            rejection_count,
            min_rejection_count
        FROM (
            SELECT
                'run-' || substr(md5(random()::text), 0, 8) as execution_id,
                pr_id,
                commit_id,
                is_rollback,
                cfg_path,
                cfg_deps,
                account_deps,
                status,
                'terragrunt plan ' || '--terragrunt-working-dir ' || cfg_path as plan_command,
                'terragrunt apply ' || '--terragrunt-working-dir ' || cfg_path || ' -auto-approve' as deploy_command,
                new_providers, 
                ARRAY[NULL] as new_resources,
                account_name,
                account_path,
                voters,
                approval_count,
                min_approval_count,
                rejection_count,
                min_rejection_count
                
            FROM (
                SELECT 
                    *
                FROM 
                    staging_cfg_stack
            ) AS stack

            LEFT INNER JOIN (
                SELECT
                    account_name,
                    account_path,
                    account_deps,
                    voters,
                    0 as approval_count,
                    min_approval_count,
                    0 as rejection_count,
                    min_rejection_count,
                FROM
                    account_dim
            )
            ON 
                (stack.account_path = account_dim.account_path)

        )
        """
    done
    set +e
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
            "status": "waiting"
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
    local terragrunt_working_dir=$(echo $1 | tr -d '"')

    new_resources=$(get_new_providers_resources "$terragrunt_working_dir" "${new_providers[*]}")

    if [ "${#new_resources}" == 0 ]; then
        log "No new resources from new providers were detected" "INFO"
        exit 0
    fi

    log "Resources from new providers:" "INFO"
    log "${new_resources[*]}" "INFO"
    
    psql_new_resources=$(bash_arr_to_psql_arr "$new_providers")

    log "Adding new resources to execution record" "INFO"
    query """
    UPDATE
        executions
    SET
        new_resources = ARRAY[$psql_new_resources]
    WHERE
        execution_id = '$execution_id'
    ;
    """
}

update_execution_status() {
    local execution_id=$(echo $1 | tr -d '"')
    local status=$(echo $2 | tr -d '"')

    query """
    UPDATE
        executions
    SET
        status = '$status'
    WHERE 
        execution_id = '$execution_id'
    """
}

get_new_providers_resources() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local terragrunt_working_dir=$(echo $1 | tr -d '"')

    #input must be expanded bash array (e.g. "${x[*]}")
    local new_providers=$2

    tg_state_cmd_out=$(terragrunt state pull --terragrunt-working-dir $terragrunt_working_dir )
    log "Terragrunt State Output:" "DEBUG"
    log "$tg_state_cmd_out" "DEBUG"

    #TODO: Create jq filter to remove external jq_regex with test()
    jq_regex=$(echo $new_providers | tr '\n(?!$)' '|' | sed '$s/|$//')
    echo $tg_state_cmd_out | jq -r \
        --arg NEW_PROVIDERS "$jq_regex" '
        .resources 
        | map(select( (.provider | test($NEW_PROVIDERS) == true) and .mode != "data" ) 
        | {type, name} | join(".")) 
    '
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

    query --psql-extra-args "-qtAX" """
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
    local executions=$1
    local commit_queue=$2

    log "Triggered via Step Function Event" "INFO"

    var_exists "$EVENTBRIDGE_EVENT"
    sf_event=$( echo $EVENTBRIDGE_EVENT | jq '. | fromjson')
    log "Step Function Event:" "DEBUG"
    log "$sf_event" "DEBUG"

    deployed_path=$( echo $sf_event | jq '.cfg_path')
    execution_id=$( echo $sf_event | jq '.execution_id')
    is_rollback=$( echo $sf_event | jq '.is_rollback')
    status=$( echo $sf_event | jq '.status')
    pr_id=$( echo $sf_event | jq '.pr_id')
    commit_id=$( echo $sf_event | jq '.commit_id' | tr -d '"')
    new_providers_count=$( echo $sf_event | jq '.new_providers | length')

    log "Updating Execution Status" "INFO"
    update_execution_status "$execution_id" "$status"

    if [ "$is_rollback" == false ]; then
        git checkout "$commit_id" > /dev/null
        log "Updating execution record with new resources" "INFO"
        if [ "$new_providers_count" -gt 0 ]; then
            log "Config contains new providers" "INFO"
            log "Adding new provider resources to config execution record" "INFO"
            update_execution_with_new_resources "$execution_id" "$deployed_path"
        fi

        if [ "$status" == "failed" ]; then
            update_commit_queue_with_rollback_commits "$pr_id"
        fi
    fi
    set +e
}

update_commit_queue_with_rollback_commits() {
    local pr_id=$(echo $1 | tr -d '"')

    query """
    INSERT INTO commit_queue (
        commit_id,
        is_rollback,
        pr_id,
        status
    )

    SELECT
        commit_id,
        true as is_rollback,
        '$pr_id',
        'waiting' as status
    FROM (
        SELECT
            commit_id
        FROM
            commit_queue
        WHERE 
            commit_id = ANY(
                            SELECT
                                commit_id
                            FROM
                                executions
                            WHERE
                                pr_id = '$pr_id' AND
                                is_rolback = false AND
                                new_resources > 0
                        )
    ) AS sub
    ;
    ALTER TABLE commit_queue ALTER COLUMN id RESTART WITH max(id) + 1;
    
    """
}

create_executions() {
    local commit_queue=$2

    log "No Deployment or Rollback stack is in Progress" "DEBUG"
 
    log "Dequeuing next commit that is waiting" "INFO"
    IFS='|' commit_items=$(query --psql-extra-args "-qtA" """
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
            FETCH FIRST ROW ONLY
        )

    RETURNING is_rollback, commit_id
    ;
    """)

    if [ "$commit_items[0]" == true ]; then
        update_executions_with_new_rollback_stack
    else
        update_executions_with_new_deploy_stack "$commit_items[1]"
    fi
}

main() {
    set -e
    echo "first step"
    if [ -z "$CODEBUILD_INITIATOR" ]; then
        log "CODEBUILD_INITIATOR is not set" "ERROR"
        exit 1
    elif [ -z "$EVENTBRIDGE_FINISHED_RULE" ]; then
        log "EVENTBRIDGE_FINISHED_RULE is not set" "ERROR"
        exit 1
    fi
    
    log "Checking if build was triggered via a finished Step Function execution" "DEBUG"
    if [ "$CODEBUILD_INITIATOR" == "$EVENTBRIDGE_FINISHED_RULE" ]; then
        execution_finished "$execution" "$commit_queue"
    fi

    log "Checking if any Step Function executions are running" "DEBUG"
    if [ $(executions_in_progress) -eq 0 ]; then
        create_executions
    fi
    exit 0
    log "Getting Target Executions" "INFO"
    target_stack=$(get_target_stack)
    log "Target Executions" "DEBUG"
    log "$target_stack" "DEBUG"

    log "Starting Step Function Deployment Flow" "INFO"
    start_sf_executions "$target_stack"

    log "Uploading Updated PR Queue" "INFO"
    upload_executions $executions
    set +e
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi