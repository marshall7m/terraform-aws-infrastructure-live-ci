#!/bin/bash
# shellcheck disable=SC2154
# SC2154: all variables are interpolated within the Terraform module via the templatefile() function

set -e

echo "Creating testing user"
aws rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn "${cluster_arn}" \
  --secret-arn "${secret_arn}" \
  --database "${db_name}" \
  --sql "${create_testing_user_sql}"