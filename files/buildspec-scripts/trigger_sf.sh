#!/bin/bash

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
source "$DIR/utils.sh"

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
    IFS=$'\n' account_paths=($(query --psql-extra-args "-tA" "SELECT account_path FROM account_dim;"))

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
        
        query """
        CREATE TABLE staging_cfg_stack (
            cfg_path VARCHAR,
            cfg_deps TEXT[],
            new_providers TEXT[]
        );
        """

        jq_to_psql_records "$stack" "staging_cfg_stack"

        log "staging_cfg_stack table:" "DEBUG"
        log "$(query --psql-extra-args "-x" "SELECT * FROM staging_cfg_stack")" "DEBUG"

        query """
        INSERT INTO
            executions
        SELECT
            'run-' || substr(md5(random()::text), 0, 8) as execution_id,
            false as is_rollback,
            commit.pr_id as pr_id,
            commit.commit_id as commit_id,
            'refs/heads/$BASE_REF^{$( git rev-parse --verify $BASE_REF )}' as base_source_version,
            'refs/pull/' || commit.pr_id || '/head^{' || commit.commit_id || '}' as head_source_version,
            cfg_path as cfg_path,
            cfg_deps as cfg_deps,
            'waiting' as status,
            'terragrunt plan ' || '--terragrunt-working-dir ' || stack.cfg_path as plan_command,
            'terragrunt apply ' || '--terragrunt-working-dir ' || stack.cfg_path || ' -auto-approve' as deploy_command,
            new_providers as new_providers, 
            ARRAY[NULL] as new_resources,
            account.account_name as account_name,
            account.account_path as account_path,
            account.account_deps as account_deps,
            account.voters as voters,
            0 as approval_count,
            account.min_approval_count as min_approval_count,
            0 as rejection_account,
            account.min_rejection_count as min_rejection_count
        FROM (
            SELECT
                pr_id,
                commit_id
            FROM
                commit_queue
            WHERE
                commit_id = '$commit_id'
        ) commit,
        (
            SELECT
                account_name,
                account_path,
                account_deps,
                voters,
                min_approval_count,
                min_rejection_count
            FROM
                account_dim
            WHERE
                account_path = '$account_path'
        ) account,
        (
            SELECT
                *
            FROM
                staging_cfg_stack
        ) stack;
        """

        log "Execution table items for account:" "DEBUG"
        log "$(query --psql-extra-args "-x" "SELECT * FROM executions WHERE account_path = '$account_path' AND commit_id = '$commit_id'")" "DEBUG"
    done
    set +e
}

update_executions_with_new_rollback_stack() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local commit_id=$1

    query """
    CREATE OR REPLACE FUNCTION target_resources(text[]) RETURNS text AS \$\$
    DECLARE
        flags text := '';
        resource text;
    BEGIN
        FOREACH resource IN ARRAY \$1
        LOOP
            flags := flags || ' -target ' || resource;
        END LOOP;
        RETURN flags;
    END;
    \$\$ LANGUAGE plpgsql;

    INSERT INTO
        executions
    SELECT
        'run-' || substr(md5(random()::text), 0, 8) as execution_id,
        true as is_rollback,
        pr_id,
        commit_id,
        base_source_version,
        head_source_version,
        cfg_path,
        cfg_deps,
        'waiting' as status,
        'terragrunt destroy' || target_resources(new_resources) as plan_command,
        'terragrunt destroy' || target_resources(new_resources) || ' -auto-approve' as deploy_commmand,
        new_providers,
        new_resources,
        account_name,
        account_deps,
        account_path,
        voters,
        0 as approval_count,
        min_approval_count,
        0 as rejection_count,
        min_rejection_count
    FROM
        executions
    WHERE
        commit_id = '$commit_id' AND
        cardinality(new_resources) > 0
    """
}

get_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local terragrunt_working_dir=$1

    log "Running Terragrunt Providers Command" "INFO"
    tg_providers_cmd_out=$( terragrunt providers --terragrunt-working-dir $terragrunt_working_dir )
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
    query """
    UPDATE
        executions
    SET
        new_resources = string_to_array('$psql_new_resources', ' ')
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

    deployed_path=$( echo $sf_event | jq '.cfg_path' | tr -d '"')
    execution_id=$( echo $sf_event | jq '.execution_id' | tr -d '"')
    is_rollback=$( echo $sf_event | jq '.is_rollback' | tr -d '"')
    status=$( echo $sf_event | jq '.status' | tr -d '"')
    pr_id=$( echo $sf_event | jq '.pr_id' | tr -d '"')
    commit_id=$( echo $sf_event | jq '.commit_id' | tr -d '"')
    new_providers=$( echo $sf_event | jq '.new_providers')

    log "Updating Execution Status" "INFO"
    update_execution_status "$execution_id" "$status"

    if [ "$is_rollback" == false ]; then
        git checkout "$commit_id" > /dev/null
        if [ "$(echo "$new_providers" | jq '. | length')" -gt 0 ]; then
            log "Config contains new providers" "INFO"
            log "Adding new provider resources to config execution record" "INFO"
            update_execution_with_new_resources "$execution_id" "$deployed_path" "$new_providers"
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
    
    log "Dequeuing next PR if commit queue is empty" "INFO"
    pr_items=$(query --psql-extra-args "-qtA" """
    IF (SELECT count(*) FROM commit_queue WHERE status = 'waiting') = 0 THEN
        RAISE NOTICE 'Pulling next PR from queue';
        UPDATE
            pr_queue
        SET
            status = 'running'
        WHERE 
            id = (
                SELECT
                    id
                FROM
                    pr_queue
                WHERE
                    status = 'waiting'
                LIMIT 1
            )
        RETURNING pr_id, head_ref;
    END IF;
    """)

    pr_items=(${pr_items//|/ })

    if [ ${#pr_items} -ne 0 ]; then
        log "Updating commit queue with dequeued PR's most recent commit" "INFO"

        pr_id="${pr_items[0]}"
        head_ref="${pr_items[1]}"
        log "Dequeued pr items:" "DEBUG"
        log "pr_id: $pr_id" "DEBUG"
        log "head_ref: $head_ref" "DEBUG"
        
        log "Checking out PR" "DEBUG"
        git fetch origin "pull/$pr_id/head:$head_ref"
        git checkout "$head_ref" || exit 1

        head_commit_id=$(git log --pretty=format:'%H' -n 1)
        
        query """
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
            LIMIT 1
        )

    RETURNING commit_id, is_rollback;
    """)

    commit_items=(${commit_items//|/ })
    
    if [ ${#commit_items} -eq 0 ]; then
        log "No commits to dequeue -- skipping execution creation" "INFO"
        exit 0
    fi

    commit_id="${commit_items[0]}"
    is_rollback="${commit_items[1]}"
    log "Dequeued commit items:" "DEBUG"
    log "commit_id: $commit_id" "DEBUG"
    log "rollback: ${commit_items[1]}" "DEBUG"

    if [ "$is_rollback" == "t" ]; then
        update_executions_with_new_rollback_stack
    elif [ "$is_rollback" == "f" ]; then
        update_executions_with_new_deploy_stack "${commit_items[0]}"
    else
        log "is_rollback value is invalid" "ERROR"
        exit 1
    fi
}

start_sf_executions() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    log "Getting executions that have all account dependencies and terragrunt dependencies met" "INFO"
    
    IFS=$'\n' target_execution_ids=$(query --psql-extra-args "-tA" """
    CREATE OR REPLACE FUNCTION arr_in_arr_count(text[], text[]) RETURNS int AS \$\$
    
        -- Returns the total number of array values in the first array that's in the second array

        DECLARE
            total int := 0;
            i text;
        BEGIN
            FOREACH i IN ARRAY \$1 LOOP
                IF (SELECT i = ANY (\$2)::BOOL) or i IS NULL THEN
                    total := total + 1;
                    RAISE NOTICE 'total: %', total;
                END IF;
            END LOOP;
            RETURN total;
        END;
    \$\$ LANGUAGE plpgsql;

    SELECT
        *
    INTO
        TEMP commit_executions
    FROM
        executions
    WHERE
        commit_id = (
            SELECT
                commit_id
            FROM
                commit_queue
            WHERE
                status = 'running'
        )
    AND
        is_rollback = (
            SELECT
                is_rollback
            FROM
                commit_queue
            WHERE
                status = 'running'
        )
    ;

    SELECT
        *
    INTO
        queued_executions
    FROM
        commit_executions
    WHERE
        status = 'waiting'
    ;

    -- selects executions where all account/terragrunt config dependencies are successful
    SELECT
        execution_id
    FROM
        queued_executions
    WHERE
        cardinality(account_deps) = arr_in_arr_count(account_deps, ( -- if count of dependency array == the count of successful dependencies
            -- gets accounts that have all successful executions
            SELECT ARRAY(
                SELECT
                    DISTINCT account_name
                FROM
                    commit_executions
                GROUP BY
                    account_name
                HAVING
                    COUNT(*) FILTER (WHERE status = 'success') = COUNT(*) --
            )
        ))
    AND
        cardinality(cfg_deps) = arr_in_arr_count(cfg_deps, (
            -- gets terragrunt config paths that have successful executions
            SELECT ARRAY(
                SELECT
                    DISTINCT commit_executions.cfg_path
                FROM
                    commit_executions
                WHERE 
                    status = 'success'
            )
        ))
    ;
    """)

    log "Target execution IDs: $(printf '\n\t%s' "${target_execution_ids[@]}")" "INFO"
    
    for id in "${target_execution_ids[@]}"; do
        log "Starting SF execution for execution ID: $id" "INFO"

        sf_input=$(query --psql-extra-args "-t" """
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
        

        # aws stepfunctions start-execution \
        #     --state-machine-arn $STATE_MACHINE_ARN \
        #     --name "$id" \
        #     --input "$sf_input"

        query """
        UPDATE
            executions
        SET
            status = 'running'
        WHERE 
            execution_id = '$id'   
        """ 
    done
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
        execution_finished "$execution" "$commit_queue"
    fi

    log "Checking if any Step Function executions are running" "DEBUG"
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