mock_cloudwatch_execution() {
    log "FUNCNAME=$FUNCNAME" "DEBUG"

    local execution=$1
    local finished_status=$2

    # default execution attribute values if not overridden by argument attributes
    default_execution=$(jq -n \
    --arg execution_id "run-$(openssl rand -base64 10 | tr -dc A-Za-z0-9)" \
    --arg pr_id $((1 + $RANDOM % 50)) \
    --arg commit_id "$(openssl rand -base64 40 | tr -dc A-Za-z0-9)" \
    --arg base_ref "feature-$((1 + $RANDOM % 50))" \
    --arg base_commit_id "$(openssl rand -base64 40 | tr -dc A-Za-z0-9)" \
    --arg cfg_path "$(openssl rand -base64 5 | tr -dc A-Za-z0-9)/$(openssl rand -base64 8 | tr -dc A-Za-z0-9)" \
    --arg account_name "account-$(openssl rand -base64 3 | tr -dc A-Za-z0-9)" \
    --arg account_path "$(openssl rand -base64 5 | tr -dc A-Za-z0-9)" \
    --arg voters "voter-$(openssl rand -base64 5 | tr -dc A-Za-z0-9)" '
        {
            "execution_id": $execution_id,
            "is_rollback": false,
            "pr_id": $pr_id,
            "commit_id": $commit_id,
            "base_source_version": "refs/heads/\($base_ref)^{\($base_commit_id)}",
            "head_source_version": "refs/pull/\($pr_id)/head^{\($commit_id)}",
            "cfg_path": $cfg_path,
            "cfg_deps": [],            
            "status": "running",
            "plan_command": "terragrunt plan --terragrunt-working-dir \($cfg_path)",
            "deploy_command": "terragrunt apply --terragrunt-working-dir \($cfg_path)",
            "new_providers": [],
            "new_resources": [],
            "account_name": $account_name,
            "account_path": $account_path,
            "account_deps": [],
            "voters": [$voters],
            "approval_count": 1,
            "min_approval_count": 1,
            "rejection_count": 1,
            "min_rejection_count": 1
        }
    ')

    log "Merging default execution with override attributes" "INFO"
    execution=$(echo "$default_execution" | jq \
    --arg execution "$execution" '
    ($execution | fromjson) as $execution
    | . + $execution
    ')

    log "Adding execution record to executions table" "DEBUG"
    jq_to_psql_records "$execution" "executions"

    log "Exporting execution cloudwatch event to env var: EVENTBRIDGE_EVENT" "INFO"
    export EVENTBRIDGE_EVENT=$( echo "$execution" | jq --arg status "$finished_status" '.status = $status | tostring')
    log "EVENTBRIDGE_EVENT: $(printf '\n\t' "$EVENTBRIDGE_EVENT")" "DEBUG"
}