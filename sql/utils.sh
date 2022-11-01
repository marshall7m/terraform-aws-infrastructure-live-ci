#!/bin/bash

# table_exists_check() is within a separate file to prevent terraform templatefile() 
# from interpreting function definition as a variable to interpolate 
table_exists_check () {
    local table="$1"
    local cluster_arn="$2"
    local secret_arn="$3"
    local database="$4"
    local schema="$5"
    local endpoint_url="$6"

    echo "Table: $table"
    exists=false
    while [[ "$exists" == false ]]; do
        sleep 5s
        # `isNull`` will return `null` if table exists and `true ` if table does not exists
        exists=$(aws "${endpoint_url}" rds-data execute-statement \
            --continue-after-timeout \
            --resource-arn "${cluster_arn}" \
            --secret-arn "${secret_arn}" \
            --database "${database}" \
            --sql "SELECT to_regclass('${schema}.${table}')" | jq '.records[0][0].isNull != true')
        
        echo "Exists: $exists"
    done
}