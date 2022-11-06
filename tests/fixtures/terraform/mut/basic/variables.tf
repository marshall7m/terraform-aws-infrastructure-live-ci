variable "github_token_ssm_value" {
  description = <<EOF
Registered Github webhook token associated with the Github provider. The token will be used by the Merge Lock Lambda Function.
If not provided, module looks for pre-existing SSM parameter via `var.github_token_ssm_key`".
The permissions for the token is dependent on if the repo has public or private visibility.
Permissions:
  private:
    - repo
  public:
    - repo:status
See more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps
EOF
  type        = string
  sensitive   = true
}

variable "metadb_name" {
  description = "Name of the metadb"
  type        = string
  default     = "metadb"
}

variable "metadb_username" {
  description = "Master username of the metadb"
  type        = string
  default     = "postgres"
}

variable "base_branch" {
  description = "Base branch for repository that all PRs will compare to"
  type        = string
  default     = "master"
}

variable "enforce_admin_branch_protection" {
  description = <<EOF
  Determines if the branch protection rule is enforced for the GitHub repository's admins. 
  This essentially gives admins permission to force push to the trunk branch and can allow their infrastructure-related commits to bypass the CI pipeline.
EOF
  type        = bool
  default     = false
}

variable "commit_status_config" {
  description = <<EOF
Determine which commit statuses should be sent for each of the specified pipeline components. 
The commit status will contain the current state (e.g pending, success, failure) and will link to 
the component's associated AWS console page.

Each of the following descriptions specify where and what the commit status links to:

PrPlan: CloudWatch log stream displaying the Terraform plan for a directory within the open pull request
CreateDeployStack: CloudWatch log stream displaying the execution metadb records that were created for 
  the merged pull request
Plan: CloudWatch log stream displaying the Terraform plan for a directory within the merged pull request
Apply: CloudWatch log stream displaying the Terraform apply output for a directory within the merged pull request
Execution: AWS Step Function page for the deployment flow execution 
EOF
  type = object({
    PrPlan            = optional(bool)
    CreateDeployStack = optional(bool)
    Plan              = optional(bool)
    Apply             = optional(bool)
    Execution         = optional(bool)
  })
  default = {
    PrPlan            = true
    CreateDeployStack = true
    Plan              = true
    Apply             = true
    Execution         = true
  }
}

variable "metadb_ci_username" {
  description = "Name of the metadb user used for the ECS tasks"
  type        = string
  default     = "ci_user"
}

variable "metadb_schema" {
  description = "Schema for AWS RDS Postgres db"
  type        = string
  default     = "test"
}

variable "registry_username" {
  description = "Private Docker registry username used to authenticate ECS task to pull docker image"
  type        = string
  default     = "mut-user"
}

variable "registry_password" {
  description = "Private Docker registry password used to authenticate ECS task to pull docker image"
  type        = string
  default     = "mock-password"
  sensitive   = true
}

variable "create_github_token_ssm_param" {
  description = "Determines if the merge lock AWS SSM Parameter Store value should be created"
  type        = bool
  default     = true
}

variable "approval_request_sender_email" {
  description = "Email address to use for sending approval requests"
  type        = string
  default     = null
}

variable "send_verification_email" {
  description = <<EOF
  Determines if an email verification should be sent to the var.approval_request_sender_email address. Set
  to true if the email address is not already authorized to send emails via AWS SES.
  EOF
  type        = bool
  default     = false
}

variable "approval_sender_arn" {
  description = "AWS SES identity ARN used to send approval emails"
  type        = string
  default     = null
}

variable "create_approval_sender_policy" {
  description = "Determines if an identity policy should be attached to approval sender identity"
  type        = bool
  default     = true
}

variable "metadb_subnet_group_name" {
  description = "Name of the metab subnet group name (defaults to metadb cluster identifier)"
  type        = string
  default     = null
}

variable "create_metadb_subnet_group" {
  description = "Determines if a AWS RDS subnet group should be created for the metadb"
  type        = bool
  default     = false
}

variable "metadb_cluster_arn" {
  description = "Metadb cluster ARN that will be used for metadb setup queries (used for local metadb testing)"
  type        = string
  default     = null
}

variable "metadb_secret_arn" {
  description = "Metadb secret ARN that will be used for metadb setup queries (used for local metadb testing)"
  type        = string
  default     = null
}

variable "ecs_image_address" {
  description = <<EOF
Docker registry image to use for the ECS Fargate containers. If not specified, this Terraform module's GitHub registry image
will be used with the tag associated with the version of this module. 
EOF
  type        = string
  default     = null
}

variable "webhook_receiver_image_address" {
  description = <<EOF
Docker registry image to use for the webhok receiver Lambda Function. If not specified, this Terraform module's GitHub registry image
will be used with the tag associated with the version of this module. 
EOF
  type        = string
  default     = null
}

variable "local_task_common_env_vars" {
  description = "ECS task env vars to set for local testing terraform module"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}