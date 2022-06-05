#!/bin/bash

# table_exists_check() is within a separate file to prevent terraform templatefile() 
# from interpreting function definition as a variable to interpolate 
table_exists_check () {
    echo "Table: $1"
    exists=false
    while [[ "$exists" == false ]]; do
        sleep 5s
        # `isNull`` will return `null` if table exists and `true ` if table does not exists
        exists=$(aws rds-data execute-statement \
            --continue-after-timeout \
            --resource-arn ${2} \
            --secret-arn ${3} \
            --database ${4} \
            --sql "SELECT to_regclass('prod.$1')" | jq '.records[0][0].isNull != true')
        
        echo "Exists: $exists"
    done
}