#!/bin/bash
echo "CODEBUILD_RESOLVED_SOURCE_VERSION: $CODEBUILD_RESOLVED_SOURCE_VERSION"
echo "REPO_FULL_NAME: $REPO_FULL_NAME"
echo "MERGE_LOCK: $MERGE_LOCK"

if [ "$MERGE_LOCK" != "none" ]; then
    data=$(cat <<EOF
    {
        "state": "pending", 
        "description": "Merging Terragrunt changes is locked. PR #${MERGE_LOCK} integration is running"
    }
EOF
    )
    curl -s -X POST \
        -H 'Content-Type: application/json' \
        --data "$data" \
        https://${GITHUB_TOKEN}:x-oauth-basic@api.github.com/repos/${REPO_FULL_NAME}/statuses/${CODEBUILD_RESOLVED_SOURCE_VERSION}
elif [ "$MERGE_LOCK" == "none" ]; then
    curl -s -X POST \
        -H 'Content-Type: application/json' \
        --data '{"state": "success", "description": "Merging Terragrunt changes is unlocked"}' \
        https://${GITHUB_TOKEN}:x-oauth-basic@api.github.com/repos/${REPO_FULL_NAME}/statuses/${CODEBUILD_RESOLVED_SOURCE_VERSION}
else
    echo "Invalid merge lock value: $MERGE_LOCK" && exit 1
fi