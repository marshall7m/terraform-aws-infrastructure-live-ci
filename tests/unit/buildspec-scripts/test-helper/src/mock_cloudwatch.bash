mock_cloudwatch_execution() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

    local execution=$1
    local finished_status=$2

    log "Adding execution record to executions table" "DEBUG"
    res=$(bash "$DIR"/mock_tables.bash \
        --table "executions" \
        --items "$execution" \
        --random-defaults \
        --results-to-json \
        --results-out-dir "$BATS_TEST_TMPDIR" \
    | jq '.mock_filepath' | tr -d '"' | xargs -I {} jq '.' {} )

    log "Mock execution record:" "DEBUG"
    log "$res" "DEBUG"

    log "Exporting execution cloudwatch event to env var: EVENTBRIDGE_EVENT" "INFO"
    export EVENTBRIDGE_EVENT=$( echo "$res" | jq --arg status "$finished_status" '.status = $status')
    log "EVENTBRIDGE_EVENT:" "DEBUG"
    log "$EVENTBRIDGE_EVENT" "DEBUG"
}