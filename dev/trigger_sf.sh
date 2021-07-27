log "Creating Step Function Input" "INFO"
sf_input=$(jq -n '{}')

# add PR to CodeBuild source version parameter for quicker downloads since CodeBuild will only have to download the PR instead of entire git repo
sf_input=$( echo $sf_input | jq \
    --arg source_version "$GIT_SOURCE_VERSION" \
    --arg rollback_source_version "$GIT_ROLLBACK_SOURCE_VERSION" \
    '. + {"source_version": $source_version, "rollback_source_version": $rollback_source_version}')
log "Step Function Input:" "INFO"
log "${sf_input}" "INFO"


execution_id=$(aws stepfunctions start-execution --state-machine-arn $STATE_MACHINE_ARN --input "${sf_input}" \
            | jq '.executionArn | split(":")[-1]')
        
aws s3api put-object \
    --acl private \
    --body $execution_file_path \
    --bucket $
    --key executions/$execution_id.json
aws sdb delete-attributes --item-name $PULL_REQUEST_ID --domain-name $DOMAIN_NAME