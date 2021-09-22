mock_cloudwatch_execution() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

    local execution=$1
    local finished_status=$2

    log "Adding execution record to executions table" "DEBUG"
    res=$(bash "$DIR"/mock_tables.bash --table "executions" --items "$execution" --random-defaults)

    log "Exporting execution cloudwatch event to env var: EVENTBRIDGE_EVENT" "INFO"
    export EVENTBRIDGE_EVENT=$( echo "$res" | jq --arg status "$finished_status" '.status = $status | tostring')
    log "EVENTBRIDGE_EVENT: $(printf '\n\t' "$EVENTBRIDGE_EVENT")" "DEBUG"
}