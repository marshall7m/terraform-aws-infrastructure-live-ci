locals {
  remote_provider = <<EOF
provider "aws" {}
EOF

  local_provider = <<EOF
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

    # koxudaxi/local-data-api proxy container
    rdsdata = var.metadb_endpoint_url

    # moto
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

    # local stack
    # s3             = "http://s3.localhost.localstack.cloud:4566"
    # cloudwatch     = "http://localhost:4566"
    # iam            = "http://localhost:4566"
    # lambda         = "http://localhost:4566"
    # s3             = "http://s3.localhost.localstack.cloud:4566"
    # secretsmanager = "http://localhost:4566"
    # sns            = "http://localhost:4566"
    # ssm            = "http://localhost:4566"
    # sts            = "http://localhost:4566"
  }
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = get_env("IS_REMOTE") == "true" ? local.remote_provider : local.local_provider
}