provider "aws" {
  skip_credentials_validation = var.skip_credentials_validation
  skip_metadata_api_check     = var.skip_metadata_api_check
  skip_requesting_account_id  = var.skip_requesting_account_id
  s3_use_path_style           = var.s3_use_path_style

  endpoints {
    # amazon/aws-stepfunctions-local
    stepfunctions = var.sf_endpoint_url

    # terraform-aws-infrastructure-live-ci/local-data-api
    rdsdata = var.metadb_endpoint_url

    # motoserver/moto
    ses            = var.moto_endpoint_url
    rds            = var.moto_endpoint_url
    ecs            = var.ecs_endpoint_url
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