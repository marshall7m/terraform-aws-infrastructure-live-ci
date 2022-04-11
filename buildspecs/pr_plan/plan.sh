#!/bin/bash

for account in $(echo "$ACCOUNT_DIM" | jq -r -c '. | .[]'); do
    echo "Account Record:"
    echo "$account"
    account_path=$(echo "$account" | jq -r '.path')
    echo "Account Path: $account_path"
    head_ref=$(git branch -r --contains "$CODEBUILD_RESOLVED_SOURCE_VERSION" | tr -d " ")
    echo "Remote Head Ref: $head_ref"
    diff_filepaths=($(git diff "$CODEBUILD_WEBHOOK_BASE_REF" "$head_ref" --name-only --diff-filter=AM -- $account_path/**.tf $account_path/**.hcl))
    echo "Filepath Count: ${#diff_filepaths[@]}"
    if [ ${#diff_filepaths[@]} -gt 0 ]; then
        diff_paths=()
        for filepath in "${diff_filepaths[@]}"; do
            diff_paths+=($(dirname $filepath))
        done

        diff_paths=($(echo "${diff_paths[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
        
        echo "New/Modified Directories:"
        printf '%s\n' "${diff_paths[@]}"
        echo "Count: ${#diff_paths[@]}"

        plan_role_arn=$(echo "$account" | jq -r '.plan_role_arn')
        echo "Plan Role ARN: $plan_role_arn"
        for path in "${diff_paths[@]}"; do
            echo "Config Path: $path"
            terragrunt plan --terragrunt-working-dir "$path" --terragrunt-iam-role "$plan_role_arn"
        done
    else
        echo "No New/Modified Terraform configurations within account -- skipping Terraform plan"
    fi
done