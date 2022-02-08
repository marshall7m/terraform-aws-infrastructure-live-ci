variable "common_tags" {
  description = "Tags to add to all resources"
  type        = map(string)
  default     = {}
}

variable "account_parent_cfg" {
  description = "Any modified child filepath of the parent path will be processed within the parent path associated Map task"
  type = list(object({
    name                     = string
    path                     = string
    voters                   = list(string)
    approval_count_required  = number
    rejection_count_required = number
    dependencies             = list(string)
  }))
}

variable "approval_request_sender_email" {
  description = "Email address to use for sending approval requests"
  type        = string
}

variable "base_branch" {
  description = "Base branch for repository that all PRs will compare to"
  type        = string
  default     = "master"
}

# CODEBUILD #

variable "merge_lock_build_name" {
  description = "Codebuild project name used for determine if infrastructure related PR can be merged into base branch"
  type        = string
  default     = null
}

variable "terra_run_img" {
  description = "Docker, ECR or AWS CodeBuild managed image to use for the terra_run CodeBuild project that runs plan/apply commands"
  type        = string
  default     = null
}

variable "terraform_version" {
  description = "Terraform version used for trigger_sf and terra_run builds. If repo contains a variety of version constraints, implementing a dynamic version manager (e.g. tfenv) is recommended"
  type        = string
  default     = "1.0.2"
}

variable "terragrunt_version" {
  description = "Terragrunt version used for trigger_sf and terra_run builds"
  type        = string
  default     = "0.31.0"
}

variable "plan_role_name" {
  description = "Name of the IAM role used for running terr* plan commands"
  type        = string
  default     = null
}

variable "plan_role_assumable_role_arns" {
  description = "List of IAM role ARNs the plan CodeBuild action can assume"
  type        = list(string)
  default     = []
}

variable "plan_role_policy_arns" {
  description = "List of IAM policy ARNs that will be attach to the plan Codebuild action"
  type        = list(string)
  default     = []
}

variable "apply_role_name" {
  description = "Name of the IAM role used for running terr* apply commands"
  type        = string
  default     = null
}

variable "apply_role_assumable_role_arns" {
  description = "List of IAM role ARNs the apply CodeBuild action can assume"
  type        = list(string)
  default     = []
}

variable "apply_role_policy_arns" {
  description = "List of IAM policy ARNs that will be attach to the apply Codebuild action"
  type        = list(string)
  default     = []
}

variable "terra_run_env_vars" {
  description = "Environment variables that will be provided for tf plan/apply builds"
  type = list(object({
    name  = string
    value = string
    type  = optional(string)
  }))
  default = []
}

variable "build_tags" {
  description = "Tags to attach to AWS CodeBuild project"
  type        = map(string)
  default     = {}
}

variable "codebuild_vpc_config" {
  description = <<EOF
AWS VPC configurations associated with all CodeBuild projects within this module. 
The subnets must have the approriate security groups to reach the subnet that the db is associated with.
Ensure that there are enough IP addresses within the subnet to host the two codebuild projects.
EOF
  type = object({
    vpc_id  = string
    subnets = list(string)
  })
}

# GITHUB-WEBHOOK #

variable "repo_full_name" {
  description = "Full name of the GitHub repository in the form of `user/repo`"
  type        = string
}

variable "file_path_pattern" {
  description = "Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension."
  type        = string
  default     = ".+\\.(hcl|tf)$"
}

variable "api_name" {
  description = "Name of AWS Rest API"
  type        = string
  default     = null
}

## SSM ##

### MERGE-LOCK ##

variable "merge_lock_ssm_key" {
  description = "SSM Parameter Store key used for locking infrastructure related PR merges"
  type        = string
  default     = null
}

### GITHUB-TOKEN ###

variable "github_token_ssm_description" {
  description = "Github token SSM parameter description"
  type        = string
  default     = "Github token used for setting PR merge locks for live infrastructure repo"
}

variable "github_token_ssm_key" {
  description = "AWS SSM Parameter Store key for sensitive Github personal token"
  type        = string
  default     = "github-webhook-validator-token" #tfsec:ignore:GEN001
}

variable "github_token_ssm_value" {
  description = "Registered Github webhook token associated with the Github provider. If not provided, module looks for pre-existing SSM parameter via `github_token_ssm_key`"
  type        = string
  default     = ""
  sensitive   = true
}

variable "create_github_token_ssm_param" {
  description = "Determines if an AWS System Manager Parameter Store value should be created for the Github token"
  type        = bool
  default     = true
}

variable "github_token_ssm_tags" {
  description = "Tags for Github token SSM parameter"
  type        = map(string)
  default     = {}
}

# STEP-FUNCTION #

variable "step_function_name" {
  description = "Name of AWS Step Function machine"
  type        = string
  default     = "infrastructure-live-ci"
}

variable "cloudwatch_event_rule_name" {
  description = "Name of the CloudWatch event rule that detects when the Step Function completes an execution"
  type        = string
  default     = null
}

variable "trigger_step_function_build_name" {
  description = "Name of AWS CodeBuild project that will trigger the AWS Step Function"
  type        = string
  default     = null
}

variable "terra_run_build_name" {
  description = "Name of AWS CodeBuild project that will run Terraform commmands withing Step Function executions"
  type        = string
  default     = null
}

# metadb

variable "metadb_name" {
  description = "Name of the AWS RDS db"
  type        = string
  default     = null
}

variable "metadb_username" {
  description = "Master username of the metadb"
  type        = string
  default     = null
}

variable "metadb_password" {
  description = "Master password for the metadb"
  type        = string
  sensitive   = true
}

variable "metadb_port" {
  description = "Port for AWS RDS Postgres db"
  type        = number
  default     = 5432
}

variable "metadb_publicly_accessible" {
  description = "Determines if metadb is publicly accessible outside of it's associated VPC"
  type        = bool
  default     = false
}

variable "metadb_security_group_ids" {
  description = "AWS VPC security group to associate the metadb with. Must allow inbound traffic from the subnet(s) that the Codebuild projects are associated with under `var.codebuild_vpc_config`"
  type        = list(string)
  default     = []
}

variable "metadb_subnets_group_name" {
  description = "AWS VPC subnet group name to associate the metadb with"
  type        = string
}

variable "metadb_availability_zones" {
  description = "AWS availability zones that the metadb RDS cluster will be hosted in. Recommended to define atleast 3 zones."
  type        = list(string)
  default     = null
}

variable "enable_metadb_http_endpoint" {
  description = "Enables AWS SDK connection to the metadb via data API HTTP endpoint. Needed in order to connect to metadb from outside of metadb's associated VPC"
  type        = bool
  default     = false
}

variable "metadb_ci_username" {
  description = "Name of the metadb user used for the Codebuild projects"
  type        = string
  default     = "ci_user"
}

variable "metadb_ci_password" {
  description = "Password for the metadb user used for the Codebuild projects"
  type        = string
  sensitive   = true
}