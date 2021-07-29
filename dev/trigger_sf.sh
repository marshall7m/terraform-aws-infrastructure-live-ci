log "Creating Step Function Input" "INFO"
sf_input=$(jq -n '{}')

# add PR to CodeBuild source version parameter for quicker downloads since CodeBuild will only have to download the PR instead of entire git repo
sf_input=$( echo $sf_input | jq \
    --arg source_version "$GIT_SOURCE_VERSION" \
    --arg rollback_source_version "$GIT_ROLLBACK_SOURCE_VERSION" \
    '. + {"source_version": $source_version, "rollback_source_version": $rollback_source_version}')
log "Step Function Input:" "INFO"
log "${sf_input}" "INFO"

sf_name="${pull_request_id}-${head_ref_current_commit_id}"
log "Execution Name: ${sf_name}" "INFO"

log "Uploading execution artifact to S3" "INFO"
aws s3api put-object \
    --acl private \
    --body $execution_file_path \
    --bucket $
    --key executions/$execution_id.json

log "Starting Execution" "INFO"
aws stepfunctions start-execution \
    --state-machine-arn $STATE_MACHINE_ARN \
    --name "${sf_name}" \
    --input "${sf_input}"