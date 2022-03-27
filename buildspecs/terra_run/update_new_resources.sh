#!/bin/bash

if [ -n "$NEW_PROVIDERS" ]; then
    echo "Adding new provider resources to execution record"

    echo "Switching back to CodeBuild base IAM role"

    
    new_resources="$(terragrunt state pull --terragrunt-working-dir "$CFG_PATH" | jq -r \
    --arg new_providers "$NEW_PROVIDERS" '
        .resources | map(
            select(
                (((.provider | match("(?<=\").+(?=\")").string) | IN($new_providers[]))
                and .mode != "data")
            )
        | {type, name} | join("."))
    ')"

    echo "New resources:"
    echo "$new_resources"

    params="$(echo "$new_resources" | jq \
    --arg new_providers "$NEW_PROVIDERS" \
    --arg execution_id "$EXECUTION_ID" '
        [
            {
                "name": "new_resources",
                "value": {
                    "arrayValue": {
                        "arrayValues": {
                            "stringValues": .
                        }
                    }
                }
            },
            {
                "name": "execution_id",
                "value": {
                    "stringValue": $execution_id
                }
            }
        ] | tostring
    ')"

    echo "RDS execute parameters:"
    echo "$params"

    # use base codebuild role to connect to metadb
    echo "Unsetting AWS_PROFILE: $AWS_PROFILE"
    unset "$AWS_PROFILE"

    echo "Adding new resources to execution record"
    aws rds-data execute-statement \
    --resource-arn "$METADB_CLUSTER_ARN" \
    --database "$METADB_NAME" \
    --secret-arn "$METADB_SECRET_ARN" \
    --sql "UPDATE executions SET new_resources = string_to_array('', ' ') WHERE execution_id = :id;" \
    --parameters "$params"
else
    echo "New provider resources were not created -- skipping"
fi