#!/bin/bash
echo "CODEBUILD_RESOLVED_SOURCE_VERSION: $CODEBUILD_RESOLVED_SOURCE_VERSION"
echo "REPO_FULL_NAME: $REPO_FULL_NAME"

if [ "$MERGE_LOCK" == "true" ]; then
    running_pr=$(psql -qtAX -c "SELECT DISTINCT pr_id FROM executions WHERE status = 'running'")
    data=$(cat <<EOF
    {
        "state": "pending", 
        "description": "Merging Terragrunt changes is locked. PR #${running_pr} integration is running"
    }
EOF
    )
    curl -s -X POST \
        -H 'Content-Type: application/json' \
        --data "$data" \
        https://${GITHUB_TOKEN}:x-oauth-basic@api.github.com/repos/${REPO_FULL_NAME}/statuses/${CODEBUILD_RESOLVED_SOURCE_VERSION}
elif [ "$MERGE_LOCK" == "false" ]; then
    curl -s -X POST \
        -H 'Content-Type: application/json' \
        --data '{"state": "success", "description": "Merging Terragrunt changes is unlocked"}' \
        https://${GITHUB_TOKEN}:x-oauth-basic@api.github.com/repos/${REPO_FULL_NAME}/statuses/${CODEBUILD_RESOLVED_SOURCE_VERSION}
else
    echo "Invalid merge lock value: $MERGE_LOCK" && exit 1
fi