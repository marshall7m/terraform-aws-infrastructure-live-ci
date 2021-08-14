#!/bin/bash

source utils.sh

get_tg_providers() {
    local terragrunt_working_dir=$1
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    terragrunt providers \
        --terragrunt-working-dir $terragrunt_working_dir 
}

get_new_providers() {
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

update_pr_queue_with_new_providers() {
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

    #TODO: Add new providers to path's object
}

update_pr_queue_with_new_resources() {
    local pr_queue=$1
    local terragrunt_working_dir=$2

    #TODO: Retrieve new providers from path object
    new_providers=$(echo $pr_queue)

    new_resources=$(get_new_providers_resources "$terragrunt_working_dir" "${new_providers[*]}")

    if [ "${#new_resources}" != 0 ]; then
        log "Resources from new providers:" "INFO"
        echo "${new_resources[*]}" "INFO"
    else
        log "No new resources from new providers were detected" "INFO"
        exit 0
    fi
}

get_tg_state() {
    local terragrunt_working_dir=$1
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    terragrunt state pull \
        --terragrunt-working-dir $terragrunt_working_dir 
}

get_new_providers_resources() {
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