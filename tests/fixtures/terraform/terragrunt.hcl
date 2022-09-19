locals {
  local_provider = <<EOF

locals {
  local_task_common_env_vars = [
    {
      name = "SSM_ENDPOINT_URL"
      value = var.moto_endpoint_url
    },
    {
      name = "LAMBDA_ENDPOINT_URL"
      value = var.moto_endpoint_url
    },
    {
      name = "SF_ENDPOINT_URL"
      value = var.sf_endpoint_url
    },
    {
      name = "AWS_S3_ENDPOINT"
      value = var.moto_endpoint_url
    },
    {
      name = "AWS_DYNAMODB_ENDPOINT"
      value = var.moto_endpoint_url
    },
    {
      name = "AWS_IAM_ENDPOINT"
      value = var.moto_endpoint_url
    },
    {
      name = "AWS_STS_ENDPOINT"
      value = var.moto_endpoint_url
    },
    {
      name = "METADB_ENDPOINT_URL"
      value = var.metadb_endpoint_url
    },
    {
      name = "S3_BACKEND_FORCE_PATH_STYLE"
      value = "true"
    },
  ]
}  
variable "moto_endpoint_url" {
  description = "Endpoint URL for standalone moto server"
  type        = string
}

variable "sf_endpoint_url" {
  description = "Endpoint URL for Step Function service"
  type        = string
}

provider "aws" {
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    # amazon/aws-stepfunctions-local
    stepfunctions = var.sf_endpoint_url

    # terraform-aws-infrastructure-live-ci/local-data-api
    rdsdata = var.metadb_endpoint_url

    # motoserver/moto
    ses            = var.moto_endpoint_url
    rds            = var.moto_endpoint_url
    ecs            = var.moto_endpoint_url
    ec2            = var.moto_endpoint_url
    events         = var.moto_endpoint_url
    cloudwatch     = var.moto_endpoint_url
    logs           = var.moto_endpoint_url
    iam            = var.moto_endpoint_url
    s3             = var.moto_endpoint_url
    lambda         = var.moto_endpoint_url
    secretsmanager = var.moto_endpoint_url
    sns            = var.moto_endpoint_url
    ssm            = var.moto_endpoint_url
    sts            = var.moto_endpoint_url
  }
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = get_env("IS_REMOTE", "") == "" ? local.local_provider : ""
}