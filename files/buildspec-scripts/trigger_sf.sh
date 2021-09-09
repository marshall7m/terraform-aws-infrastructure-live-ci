#!/bin/bash

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
source "$DIR/utils.sh"

get_tg_plan_out() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local terragrunt_working_dir=$1
    
    # returns the exitcode instead of the plan output (0=no plan difference, 1=error, 2=detected plan difference)
    terragrunt run-all plan \
        --terragrunt-working-dir $terragrunt_working_dir \
        --terragrunt-non-interactive \
        -detailed-exitcode 2>&1
}

get_diff_paths() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local tg_plan_out=$1
    local git_root=$2
    

    # use pcregrep with -M multiline option to scan terragrunt plan output for
    # directories that exited plan with exit status 2 (diff in plan)
    # -N flag defines the convention for newline and CRLF allows for all of the conventions
    abs_paths=$( echo "$tg_plan_out" \
        | pcregrep -Mo -N CRLF '(?<=exit\sstatus\s2\n).+?(?=\])' \
        | grep -oP 'prefix=\[\K.+'
    )
    log "Absolute paths: $(printf '\n\t%s\n' "${abs_paths[@]}")" "DEBUG"

    diff_paths=()
    while read -r dir; do
        diff_paths+=($(realpath -e --relative-to="$git_root" "$dir"))
    done <<< "$abs_paths"
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
    echo "$stack" | jq 'map(.cfg_path)' | jq -c '.[]' | while read dir; do
        dir=$(echo "$dir" | tr -d '"')
        log "Directory: $dir" "DEBUG"
        get_new_providers "$dir"

        stack=$(echo $stack | jq \
        --arg dir "$dir" \
        --arg new_providers "${new_providers[*]}" '
        (if $new_providers == null or $new_provders == "" then [] else ($new_providers | split(" ")) end) as $new_providers
        | map( if .cfg_path == $dir then .new_prioviders = $new_providers else . end)
        ')
        # stack=$(echo $stack | jq \
        # --arg dir "$dir" \
        # --arg new_providers "${new_providers[*]}" '
        # map( if .cfg_path == $dir then .new_prioviders = ["doo"] else . end)
        # ')
    done
    
    echo "$stack"
}

create_stack() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

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

get_target_stack() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local executions=$2
    local commit_id=$2

    log "Getting list of accounts that have no account dependencies or no account dependencies that waiting or running" "DEBUG"

    query """
    SELECT
        account_name
    FROM 
        executions
    WHERE
        account_name NOT IN (
            SELECT
                DISTINCT ON (account_name)
            FROM
                executions
            WHERE
                commit_id = '$commit_id' AND
                status != 'success'
        )
    ;
    """
    # target_accounts=$( echo $executions | jq \
    # --arg commit_id $commit_id '
    #     map(select(.commit_id == $commit_id))
    #     | group_by(.account_name) 
    #     | map(select([.[] | .status == "success"] | all) | .[] | .account_name) 
    #     | unique
    # ')

#     log "Getting Deployment Paths from Accounts:" "INFO"
#     log "$target_accounts" "DEBUG"

#     log "Getting executions that have their dependencies finished" "DEBUG"
#     echo "$( echo $executions | jq \
#         --arg target_accounts "$target_accounts" \
#         --arg commit_id "$commit_id" '
#         ($target_accounts | fromjson) as $target_accounts
#         | map(select(.account_name | IN($target_accounts[]) and .commit_id == $commit_id))
#         | (map(select(.status | IN("success")) | .path)) as $successful_paths
#         | map(select(.status == "waiting" and [.dependencies | .[] | IN($successful_paths[]) or . == null] | all ))
#     ')"
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

start_sf_executions() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local target_stack=$1
    execution_name="run-$(uuidgen)"
    
    aws stepfunctions start-execution \
        --state-machine-arn $STATE_MACHINE_ARN \
        --name "$execution_name" \
        --input "$sf_input"
}

update_executions_with_new_deploy_stack() {
    set -e
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local commit_id=$1
    
    log "Getting Account Paths" "INFO"
    IFS=$'\n' account_paths=($(query --psql-extra-args "-tA" "SELECT account_path FROM account_dim;"))

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
        
        query """
        DROP TABLE IF EXISTS staging_cfg_stack;

        CREATE TABLE staging_cfg_stack (
            cfg_path VARCHAR,
            cfg_deps TEXT[],
            new_providers TEXT[]
        );
        """

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

        log "Execution table items for account:" "DEBUG"
        log "$(query "-x" """SELECT * FROM executions WHERE account_path = '$account_path' AND commit_id = '$commit_id'""")" "DEBUG"

        log "Removing staging_cfg_stack table" "DEBUG"
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
            new_providers+=("${provider}")
        else
            log "Status: ALREADY EXISTS" "DEBUG"
        fi
    done <<< "$cfg_providers"
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
    log "FUNCNAME=$FUNCNAME" "DEBUG"

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
    log "FUNCNAME=$FUNCNAME" "DEBUG"

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
    log "FUNCNAME=$FUNCNAME" "DEBUG"

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
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local commit_queue=$2 

    log "Dequeuing next commit that is waiting" "INFO"
    commit_items=$(query --psql-extra-args "-qtA" """
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

    RETURNING commit_id, is_rollback
    ;
    """)
    commit_items=(${commit_items//|/ })

    log "Dequeued commit items:" "DEBUG"
    log "commit_id: ${commit_items[0]}" "DEBUG"
    log "rollback: ${commit_items[1]}" "DEBUG"

    if [ "${commit_items[1]}" == true ]; then
        update_executions_with_new_rollback_stack
    else
        update_executions_with_new_deploy_stack "${commit_items[0]}"
    fi
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
        execution_finished "$execution" "$commit_queue"
    fi

    log "Checking if any Step Function executions are running" "DEBUG"
    if [ $(executions_in_progress) -eq 0 ]; then
        log "No deployment or rollback executions in progress" "DEBUG"
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