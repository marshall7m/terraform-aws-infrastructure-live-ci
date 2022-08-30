provider "github" {
  token = var.testing_integration_github_token
}

provider "aws" {
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    # amazon/aws-stepfunctions-local
    stepfunctions = "http://localhost:8083"

    # koxudaxi/local-data-api proxy container
    rdsdata = "http://127.0.0.1:8080"

    # moto
    ses            = "http://localhost:5000"
    rds            = "http://localhost:5000"
    ecs            = "http://localhost:5000"
    ec2            = "http://localhost:5000"
    events         = "http://localhost:5000"
    cloudwatch     = "http://localhost:5000"
    logs           = "http://localhost:5000"
    iam            = "http://localhost:5000"
    lambda         = "http://localhost:5000"
    secretsmanager = "http://localhost:5000"
    sns            = "http://localhost:5000"
    ssm            = "http://localhost:5000"
    sts            = "http://localhost:5000"

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