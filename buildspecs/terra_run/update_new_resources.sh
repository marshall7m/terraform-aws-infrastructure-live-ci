#!/bin/bash

if [ -n "$NEW_PROVIDERS" ] && [ "$NEW_PROVIDERS" != "[]" ] && [ "$IS_ROLLBACK" == false ]; then
    echo "Adding new provider resources to execution record"
    
    new_resources="$(terragrunt state pull --terragrunt-working-dir "$CFG_PATH" | jq -r \
    --arg new_providers "$NEW_PROVIDERS" '
        ($new_providers | fromjson) as $new_providers
        | .resources | map(
            select(
                (((.provider | match("(?<=\").+(?=\")").string) | IN($new_providers[]))
                and .mode != "data")
            )
        | {type, name} | join("."))
    ')"

    echo "New resources:"
    echo "$new_resources"

    #converting new_resources to string and converting back to array within query since arrayValues is not supported with rds-data execute-statement
    if $(echo "$new_resources" | jq 'length > 0'); then
        params="$(echo "$new_resources" | jq \
        --arg execution_id "$EXECUTION_ID" '
            [
                {
                    "name": "new_resources",
                    "value": {
                        "stringValue": (. | join(" "))
                    }
                },
                {
                    "name": "execution_id",
                    "value": {
                        "stringValue": $execution_id
                    }
                }
            ]
        ')"

        echo "RDS execute parameters:"
        echo "$params"

        # use base codebuild role to connect to metadb
        echo "Switching back to CodeBuild base IAM role"
        unset "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN"

        echo "Adding new resources to execution record"
        aws rds-data execute-statement \
            --resource-arn "$METADB_CLUSTER_ARN" \
            --database "$METADB_NAME" \
            --secret-arn "$METADB_SECRET_ARN" \
            --sql "UPDATE executions SET new_resources = string_to_array(:new_resources, ' ') WHERE execution_id = :execution_id;" \
            --parameters "$params"
    else
        echo "New provider resources were not created -- skipping"
    fi
else
    echo "New provider resources were not created -- skipping"
fi