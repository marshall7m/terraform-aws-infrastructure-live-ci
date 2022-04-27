variable "common_tags" {
  description = "Tags to add to all resources"
  type        = map(string)
  default     = {}
}
variable "prefix" {
  description = "Prefix to attach to all resources"
  type        = string
  default     = null
}

variable "account_parent_cfg" {
  description = <<EOF
AWS account-level configurations.
  - name: AWS account name (e.g. dev, staging, prod, etc.)
  - path: Parent account directory path relative to the repository's root directory path (e.g. infrastructure-live/dev-account)
  - voters: List of email addresses that will be sent approval request to
  - min_approval_count: Minimum approval count needed for CI pipeline to run deployment
  - min_rejection_count: Minimum rejection count needed for CI pipeline to decline deployment
  - dependencies: List of AWS account names that this account depends on before running any of it's deployments 
    - For example, if the `dev` account depends on the `shared-services` account and both accounts contain infrastructure changes within a PR (rare scenario but possible),
      all deployments that resolve infrastructure changes within `shared-services` need to be applied before any `dev` deployments are executed. This is useful given a
      scenario where resources within the `dev` account are explicitly dependent on resources within the `shared-serives` account.
  - plan_role_arn: IAM role ARN within the account that the plan build will assume
    - **CAUTION: Do not give the plan role broad administrative permissions as that could lead to detrimental results if the build was compromised**
  - deploy_role_arn: IAM role ARN within the account that the deploy build will assume
    - Fine-grained permissions for each Terragrunt directory within the account can be used by defining a before_hook block that
      conditionally defines that assume_role block within the directory dependant on the Terragrunt command. For example within `prod/iam/terragrunt.hcl`,
      define a before hook block that passes a strict read-only role ARN for `terragrunt plan` commands and a strict write role ARN for `terragrunt apply`. Then
      within the `deploy_role_arn` attribute here, define a IAM role that can assume both of these roles.
EOF
  type = list(object({
    name                = string
    path                = string
    voters              = list(string)
    min_approval_count  = number
    min_rejection_count = number
    dependencies        = list(string)
    plan_role_arn       = string
    deploy_role_arn     = string
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

variable "pr_plan_build_name" {
  description = "Codebuild project name used for creating Terraform plans for new/modified configurations within PR"
  type        = string
  default     = null
}

variable "pr_plan_vpc_config" {
  description = <<EOF
AWS VPC configurations associated with PR planning CodeBuild project. 
Ensure that the configuration allows for outgoing traffic for downloading associated repository sources from the internet.
EOF
  type = object({
    vpc_id             = string
    subnets            = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "pr_plan_env_vars" {
  description = "Environment variables that will be provided to open PR's Terraform planning builds"
  type = list(object({
    name  = string
    value = string
    type  = optional(string)
  }))
  default = []
}

variable "build_img" {
  description = "Docker, ECR or AWS CodeBuild managed image to use for the CodeBuild projects. If not specified, Terraform module will create an ECR image for them."
  type        = string
  default     = null
}

variable "tf_state_read_access_policy" {
  description = "AWS IAM policy ARN that allows create deploy stack Codebuild project to read from Terraform remote state resource"
  type        = string
}

variable "terraform_version" {
  description = "Terraform version used for create_deploy_stack and terra_run builds. If repo contains a variety of version constraints, implementing a dynamic version manager (e.g. tfenv) is recommended"
  type        = string
  default     = "1.0.2"
}

variable "terragrunt_version" {
  description = "Terragrunt version used for create_deploy_stack and terra_run builds"
  type        = string
  default     = "0.31.0"
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

variable "terra_run_vpc_config" {
  description = <<EOF
AWS VPC configurations associated with terra_run CodeBuild project. 
Ensure that the configuration allows for outgoing traffic for downloading associated repository sources from the internet.
EOF
  type = object({
    vpc_id             = string
    subnets            = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "create_deploy_stack_vpc_config" {
  description = <<EOF
AWS VPC configurations associated with terra_run CodeBuild project. 
Ensure that the configuration allows for outgoing traffic for downloading associated repository sources from the internet.
EOF
  type = object({
    vpc_id             = string
    subnets            = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "create_deploy_stack_graph_scan" {
  description = <<EOF
If true, the create_deploy_stack build will use the git detected differences to determine what directories to run Step Function executions for.
If false, the build will use terragrunt run-all plan detected differences to determine the executions.
Set to false if changes to the terraform resources are also being controlled outside of the repository (e.g AWS console, separate CI pipeline, etc.)
which results in need to refresh the terraform remote state to accurately detect changes.
Otherwise set to true, given that collecting changes via git will be significantly faster than collecting changes via terragrunt run-all plan.
EOF
  type        = bool
  default     = true
}

variable "codebuild_common_env_vars" {
  description = "Common env vars defined within all Codebuild projects. Useful for setting Terragrunt specific env vars required to run Terragrunt commands."
  type = list(object({
    name  = string
    value = string
    type  = optional(string)
  }))
  default = []
}

# GITHUB-WEBHOOK #

variable "repo_name" {
  description = "Name of the GitHub repository that is owned by the Github provider"
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

variable "api_stage_name" {
  description = "API deployment stage name"
  type        = string
  default     = "prod"
}

## SSM ##

### MERGE-LOCK ##

variable "merge_lock_ssm_key" {
  description = "SSM Parameter Store key used for locking infrastructure related PR merges"
  type        = string
  default     = null
}

variable "merge_lock_status_check_name" {
  description = "Name of the merge lock GitHub status"
  type        = string
  default     = "IAC Merge Lock"
}

variable "pr_approval_count" {
  description = "Number of GitHub approvals required to merge a PR with infrastructure changes"
  type        = number
  default     = null
}

variable "enfore_admin_branch_protection" {
  description = <<EOF
  Determines if the branch protection rule is enforced for the GitHub repository's admins. 
  This essentially gives admins permission to force push to the trunk branch and can allow their infrastructure-related commits to bypass the CI pipeline.
EOF
  type        = bool
  default     = false
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

variable "create_deploy_stack_build_name" {
  description = "Name of AWS CodeBuild project that will create the PR deployment stack into the metadb"
  type        = string
  default     = null
}

variable "terra_run_build_name" {
  description = "Name of AWS CodeBuild project that will run Terraform commands withing Step Function executions"
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
  default     = "root"
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

variable "metadb_schema" {
  description = "Schema for AWS RDS Postgres db"
  type        = string
  default     = "prod"
}

variable "metadb_publicly_accessible" {
  description = "Determines if metadb is publicly accessible outside of it's associated VPC"
  type        = bool
  default     = false
}

variable "metadb_security_group_ids" {
  description = "AWS VPC security group to associate the metadb with"
  type        = list(string)
  default     = []
}

variable "metadb_subnets_group_name" {
  description = "AWS VPC subnet group name to associate the metadb with"
  type        = string
  default     = null
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

variable "lambda_approval_request_vpc_config" {
  description = "VPC configuration for Lambda approval request function"
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "lambda_approval_response_vpc_config" {
  description = "VPC configuration for Lambda approval response function"
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "lambda_trigger_sf_vpc_config" {
  description = "VPC configuration for Lambda trigger_sf function"
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "trigger_sf_function_name" {
  description = "Name of the AWS Lambda function used to trigger Step Function deployments"
  type        = string
  default     = null
}