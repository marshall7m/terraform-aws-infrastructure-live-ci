locals {
  before_hook = <<-EOF
if [[ -z $SKIP_TFENV ]]; then
  echo "Scanning Terraform files for Terraform binary version constraint"
  tfenv use min-required || tfenv install min-required \
    && tfenv use min-required
else
  echo "Skip scanning Terraform files for Terraform binary version constraint"
  echo "Terraform Version: $(tfenv version-name)";
fi
  EOF
}

terraform {
  before_hook "before_hook" {
    commands = ["validate", "init", "plan", "apply", "destroy"]
    execute  = ["bash", "-c", local.before_hook]
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
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
    kms = var.moto_endpoint_url
    ecr = var.moto_endpoint_url
  }
}

provider "github" {}

EOF
}


generate "provider_variables" {
  path      = "provider_variables.tf"
  if_exists = "overwrite"
  contents  = <<EOF
variable "moto_endpoint_url" {
  description = "Endpoint URL for standalone moto server"
  type        = string
  default     = null
}

variable "metadb_endpoint_url" {
  description = "Endpoint URL that metadb setup queries will be directed to (used for local metadb testing)"
  type        = string
  default     = null
}

variable "sf_endpoint_url" {
  description = "Endpoint URL for AWS Step Function"
  type        = string
  default     = null
}

variable "ecs_endpoint_url" {
  description = "Endpoint URL for AWS ECS"
  type        = string
  default     = null
}

variable "skip_credentials_validation" {
  description = "Skip credentials validation via the STS API (set to True for local testing)"
  type        = bool
  default     = null
}

variable "skip_metadata_api_check" {
  description = "Skip the AWS Metadata API check (set to True for local testing)"
  type        = bool
  default     = null
}

variable "skip_requesting_account_id" {
  description = "Skip requesting the account ID"
  type        = bool
  default     = null
}

variable "s3_use_path_style" {
  description = "Enable the request to use path-style addressing (set to True for local testing)"
  type        = bool
  default     = null
}

variable "is_remote" {
  description = "Determines if module under testing is provisioned locally or not"
  type = bool
  default = true
}
EOF
}