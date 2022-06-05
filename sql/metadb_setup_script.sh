#!/bin/bash

set -e
source "${tf_module_path}/sql/utils.sh"

echo "Creating tables"
aws rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn ${cluster_arn} \
  --secret-arn ${secret_arn} \
  --database ${db_name} \
  --sql "${create_tables_sql}"

echo "Ensure tables exists"
table_exists_check "account_dim" ${cluster_arn} ${secret_arn} ${db_name}
table_exists_check "executions" ${cluster_arn} ${secret_arn} ${db_name}

echo "Creating CI user"
aws rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn ${cluster_arn} \
  --secret-arn ${secret_arn} \
  --database ${db_name} \
  --sql "${create_ci_user_sql}"

echo "Inserting account records into account_dim"
aws rds-data batch-execute-statement \
  --resource-arn ${cluster_arn} \
  --secret-arn ${secret_arn} \
  --database ${db_name} \
  --sql "${insert_account_dim_sql}" \
  --parameter-sets "${insert_account_dim_parameter_sets}"