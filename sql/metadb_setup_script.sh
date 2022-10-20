#!/bin/bash
# shellcheck disable=SC2154,SC1091
# SC2154: all variables are interpolated within the Terraform module via the templatefile() function
# SC1091: all variables are interpolated within the Terraform module via the templatefile() function

set -e

source "${tf_module_path}/sql/utils.sh" 

echo "Creating tables"
aws "${endpoint_url_flag}" rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn "${cluster_arn}" \
  --secret-arn "${secret_arn}" \
  --database "${db_name}" \
  --continue-after-timeout \
  --sql "${create_tables_sql}"

echo "Ensure tables exists"
table_exists_check \
  "account_dim" \
  "${cluster_arn}" \
  "${secret_arn}" \
  "${db_name}" \
  "${schema}" \
  "${endpoint_url_flag}"

table_exists_check \
  "executions" \
  "${cluster_arn}" \
  "${secret_arn}" \
  "${db_name}" \
  "${schema}" \
  "${endpoint_url_flag}"

echo "Creating CI user"
aws "${endpoint_url_flag}" rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn "${cluster_arn}" \
  --secret-arn "${secret_arn}" \
  --database "${db_name}" \
  --continue-after-timeout \
  --sql "${create_ci_user_sql}"

echo "Inserting account records into account_dim"
aws "${endpoint_url_flag}" rds-data batch-execute-statement \
  --resource-arn "${cluster_arn}" \
  --secret-arn "${secret_arn}" \
  --database "${db_name}" \
  --sql "${insert_account_dim_sql}" \
  --parameter-sets "${insert_account_dim_parameter_sets}"