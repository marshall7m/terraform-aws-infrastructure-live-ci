#!/bin/bash

for account in $(echo "$ACCOUNT_DIM" | jq -r -c '. | .[]'); do
    echo "Account Record:"
    echo "$account"
    account_path=$(echo "$account" | jq -r '.path')
    echo "Account Path: $account_path"
    head_ref=$(git branch -r --contains "$CODEBUILD_RESOLVED_SOURCE_VERSION" | xargs)
    echo "Remote Head Ref: $head_ref"
    
    diff_filepaths=($(git diff "$CODEBUILD_WEBHOOK_BASE_REF" "$head_ref" --name-only --diff-filter=AM -- $account_path/**.tf $account_path/**.hcl))
    diff_paths=()
    for filepath in "${diff_filepaths[@]}"; do
        diff_paths+=($(dirname $filepath))
    done
    
    echo "New/Modified Paths:"
    printf '%s\n' "${diff_paths[@]}"

    echo "Diff Count: ${#diff_paths[@]}"
    if [ ${#diff_paths[@]} -gt 0 ]; then
        plan_role_arn=$(echo "$account" | jq -r '.plan_role_arn')
        echo "Plan Role ARN: $plan_role_arn"
        for path in "${diff_paths[@]}"; do
            echo "Config Path: $path"
            terragrunt plan --terragrunt-working-dir "$path" --terragrunt-iam-role "$plan_role_arn"
        done
    fi
done