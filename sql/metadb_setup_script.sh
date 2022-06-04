#!/bin/bash

echo "Creating tables"
aws rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn ${cluster_arn} \
  --secret-arn ${secret_arn} \
  --database ${db_name} \
  --sql "${create_tables_sql}" || exit 1

echo "Creating CI user"
aws rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn ${cluster_arn} \
  --secret-arn ${secret_arn} \
  --database ${db_name} \
  --sql "${create_ci_user_sql}" || exit 1

echo "Inserting account records into account_dim"
aws rds-data batch-execute-statement \
  --resource-arn ${cluster_arn} \
  --secret-arn ${secret_arn} \
  --database ${db_name} \
  --sql "${insert_account_dim_sql}" \
  --parameter-sets "${insert_account_dim_parameter_sets}" || exit 1