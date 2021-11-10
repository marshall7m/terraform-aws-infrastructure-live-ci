mock_cloudwatch_execution() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

    local execution="$1"
    local finished_status="$2"
    type_map=$(jq -n '
    {
        "voters": "TEXT[]",
        "account_deps": "TEXT[]",
        "new_providers": "TEXT[]", 
        "new_resources": "TEXT[]"
    }
    ')
    
    log "Adding execution record to executions table" "DEBUG"
    res=$(bash "$DIR"/mock_tables.bash \
        --table "executions" \
        --items "$execution" \
        --type-map "$type_map" \
        --update-parents \
        --enable-defaults
    )
    
    mock_record=$(echo "$res" | jq '.[0]')
    log "Mock execution record:" "DEBUG"
    log "$mock_record" "DEBUG"

    log "Exporting execution cloudwatch event to env var: EVENTBRIDGE_EVENT" "INFO"
    export EVENTBRIDGE_EVENT=$( echo "$mock_record" | jq --arg status "$finished_status" '.status = $status')
    log "EVENTBRIDGE_EVENT:" "DEBUG"
    log "$EVENTBRIDGE_EVENT" "DEBUG"
}