#!/bin/bash
echo "Adding new provider resources to execution record"

tg_state_cmd_out=$(terragrunt state pull --terragrunt-working-dir "$CFG_PATH" )
echo "$NEW_PROVIDERS"
new_resources="$(echo "$tg_state_cmd_out" | jq -r \
--arg new_providers "$NEW_PROVIDERS" '
    .resources | map(
        select(
            (((.provider | match("(?<=\").+(?=\")").string) | IN($new_providers[]))
            and .mode != "data")
        )
    | {type, name} | join(".")) | join(" ")
')"

echo "Resources from new providers:"
echo "$new_resources"

echo "Adding new resources to execution record"
psql -c """
UPDATE executions
SET new_resources = string_to_array('$new_resources', ' ')
WHERE execution_id = '$EXECUTION_ID'
;
"""