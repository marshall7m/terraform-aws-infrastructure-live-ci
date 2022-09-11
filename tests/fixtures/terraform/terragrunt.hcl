locals {
  remote_provider = <<EOF
variable "testing_integration_github_token" {
  description = <<EOT
GitHub token used for the Terraform GitHub provider and the PyTest PyGithub API connection.
The permissions for the token is dependent on if the repo has public or private visibility.
Permissions:
  private:
    - admin:repo_hook
    - repo
    - read:org (if organization repo)
    - delete_repo
    - read:discussion
  public:
    - admin:repo_hook
    - repo:status
    - public_repo
    - read:org (if organization repo)
    - delete_repo
    - read:discussion
See more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps
EOT
  type        = string
  sensitive   = true
  default     = null
}

provider "github" {
  token = var.testing_integration_github_token
}

provider "aws" {}
EOF

  local_provider = <<EOF
variable "testing_integration_github_token" {
  description = <<EOT
GitHub token used for the Terraform GitHub provider and the PyTest PyGithub API connection.
The permissions for the token is dependent on if the repo has public or private visibility.
Permissions:
  private:
    - admin:repo_hook
    - repo
    - read:org (if organization repo)
    - delete_repo
    - read:discussion
  public:
    - admin:repo_hook
    - repo:status
    - public_repo
    - read:org (if organization repo)
    - delete_repo
    - read:discussion
See more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps
EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "moto_endpoint_url" {
  description = "Endpoint URL for standalone moto server"
  type        = string
}

variable "sf_endpoint_url" {
  description = "Endpoint URL for Step Function service"
  type        = string
}

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
  }
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = get_env("IS_REMOTE", "") != "" ? local.remote_provider : local.local_provider
}