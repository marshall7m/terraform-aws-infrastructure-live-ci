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

add_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"
    
    local pr_queue=$1
    local new_providers=$2

    check_build_env_vars

    echo "$( echo $pr_queue | jq \
    --arg account $ACCOUNT \
    --arg path $TARGET_PATH \
    --arg new_providers "$new_providers" '
        (try ($new_providers | split(" ")) // []) as $new_providers
            | .InProgress.CommitStack.InProgress.DeployStack[$account].Stack[$path].NewProviders = $new_providers
    ')"
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

update_pr_queue_with_new_providers() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local pr_queue=$1
    local terragrunt_working_dir=$2

    new_providers=$(get_new_providers "$terragrunt_working_dir")
    if [ "${#new_providers}" != 0 ]; then
        log "New Providers:" "INFO"
        log "${new_providers[*]}" "INFO"
    else
        log "No new providers were detected" "INFO"
        exit 0
    fi

    pr_queue=$(add_new_providers "$pr_queue" "${new_providers[*]}")
    log "Updated PR Queue:" "DEBUG"
    log "$pr_queue" "DEBUG"

    upload_pr_queue "$pr_queue"
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

    get_pr_queue

    exit 0
    # pr_queue=$(get_pr_queue)
        
    if [ "$DEPLOYMENT_TYPE" == "Rollout" ]; then
        if [ "$DEPLOYMENT_STAGE" == "Plan" ]; then
            update_pr_queue_with_new_providers "$pr_queue"
            terragrunt "$PLAN_COMMAND" --terragrunt-working-dir $TARGET_PATH

        elif [ "$DEPLOYMENT_STAGE" == "Deploy" ]; then
            # continue script if terragrunt cmd fails to allow pr_queue to be updated with new resources created with failed terragrunt cmd
            set +e
            terragrunt "$DEPLOY_COMMAND" --terragrunt-working-dir $TARGET_PATH
            update_pr_queue_with_new_resources "$pr_queue"

        else
            log "No Deployment Stage was specified - Set DEPLOYMENT_STAGE to ("Plan" | "Deploy")" "ERROR"
            exit 1

        fi

    elif [ "$DEPLOYMENT_TYPE" == "Rollback" ]; then
        if [ "$DEPLOYMENT_STAGE" == "Plan" ]; then
            update_pr_queue_with_destroy_targets_flags "$pr_queue"
            destroy_targets_flags=$(read_destroy_targets_flags "$pr_queue")
            terragrunt "$PLAN_COMMAND" --terragrunt-working-dir $TARGET_PATH $destroy_targets_flags

        elif [ "$DEPLOYMENT_STAGE" == "Deploy" ]; then
            destroy_targets_flags=$(read_destroy_targets_flags "$pr_queue")
            terragrunt "$DEPLOY_COMMAND" --terragrunt-working-dir $TARGET_PATH $destroy_targets_flags

        else
            log "No Deployment Stage was specified - Set DEPLOYMENT_STAGE to ("Plan" | "Deploy")" "ERROR"
            exit 1

        fi

    else
        log "No Deployment Type was specified - Set DEPLOYMENT_TYPE to ("Rollout" | "Rollback")" "ERROR"
        exit 1

    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
