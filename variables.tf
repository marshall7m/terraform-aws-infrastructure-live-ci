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

variable "send_verification_email" {
  description = <<EOF
  Determines if an email verification should be sent to the var.approval_request_sender_email address. Set
  to true if the email address is not already authorized to send emails via AWS SES.
  EOF
  type        = bool
  default     = true
}

# CODEBUILD #

variable "codebuild_source_auth_token" {
  description = <<EOF
  GitHub personal access token used to authorize CodeBuild projects to clone GitHub repos within the Terraform AWS provider's AWS account and region. 
  If not specified, existing CodeBuild OAUTH or GitHub personal access token authorization is required beforehand.
  EOF
  type        = string
  default     = null
  sensitive   = true
}

variable "pr_plan_vpc_config" {
  description = <<EOF
AWS VPC configurations associated with PR planning CodeBuild project. 
Ensure that the configuration allows for outgoing HTTPS traffic.
EOF
  type = object({
    vpc_id             = string
    subnets            = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "pr_plan_status_check_name" {
  description = "Name of the CodeBuild pr_plan GitHub status"
  type        = string
  default     = "Plan"
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
  description = "AWS IAM policy ARN that allows create_deploy_stack Codebuild project to read from Terraform remote state resource"
  type        = string
}

variable "terraform_version" {
  description = <<EOF
Terraform version used for create_deploy_stack and terra_run builds.
Version must be >= `0.13.0`.
If repo contains a variety of version constraints, implementing a 
version manager is recommended (e.g. tfenv).
EOF
  type        = string
  default     = ""
}

variable "terragrunt_version" {
  description = <<EOF
Terragrunt version used for create_deploy_stack and terra_run builds.
Version must be >= `0.31.0`.
If repo contains a variety of version constraints, implementing a 
version manager is recommended (e.g. tgswitch).
EOF
  type        = string
  default     = ""
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
Ensure that the configuration allows for outgoing HTTPS traffic.
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
Ensure that the configuration allows for outgoing HTTPS traffic.
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

variable "merge_lock_status_check_name" {
  description = "Name of the merge lock GitHub status"
  type        = string
  default     = "Merge Lock"
}
variable "create_deploy_stack_status_check_name" {
  description = "Name of the create deploy stack GitHub status"
  type        = string
  default     = "Create Deploy Stack"
}

# GITHUB WEBHOOK #

variable "repo_name" {
  description = "Name of the pre-existing GitHub repository that is owned by the Github provider"
  type        = string
}

variable "file_path_pattern" {
  description = "Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension."
  type        = string
  default     = ".+\\.(hcl|tf)$"
}


variable "api_stage_name" {
  description = "API deployment stage name"
  type        = string
  default     = "prod"
}

# GITHUB REPO #

variable "base_branch" {
  description = "Base branch for repository that all PRs will compare to"
  type        = string
  default     = "master"
}

variable "pr_approval_count" {
  description = "Number of GitHub approvals required to merge a PR with infrastructure changes"
  type        = number
  default     = null
}

variable "enforce_admin_branch_protection" {
  description = <<EOF
  Determines if the branch protection rule is enforced for the GitHub repository's admins. 
  This essentially gives admins permission to force push to the trunk branch and can allow their infrastructure-related commits to bypass the CI pipeline.
EOF
  type        = bool
  default     = false
}

variable "enable_branch_protection" {
  description = <<EOF
Determines if the branch protection rule is created. If the repository is private (most likely), the GitHub account associated with
the GitHub provider must be registered as a GitHub Pro, GitHub Team, GitHub Enterprise Cloud, or GitHub Enterprise Server account. See here for details: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches
EOF
  type        = bool
  default     = true
}

# SSM #

variable "create_merge_lock_github_token_ssm_param" {
  description = "Determines if the merge lock AWS SSM Parameter Store value should be created"
  type        = bool
}

variable "merge_lock_github_token_ssm_key" {
  description = "AWS SSM Parameter Store key for sensitive Github personal token used by the Merge Lock Lambda Function"
  type        = string
  default     = null
}

variable "merge_lock_github_token_ssm_description" {
  description = "Github token SSM parameter description"
  type        = string
  default     = "Github token used by Merge Lock Lambda Function"
}

variable "merge_lock_github_token_ssm_value" {
  description = <<EOF
Registered Github webhook token associated with the Github provider. The token will be used by the Merge Lock Lambda Function.
If not provided, module looks for pre-existing SSM parameter via `var.merge_lock_github_token_ssm_key`".
GitHub token only needs the `repo:status` permission. (see more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps)
  EOF
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_token_ssm_tags" {
  description = "Tags for Github token SSM parameter"
  type        = map(string)
  default     = {}
}

## GH-VALIDATOR-TOKEN ##

variable "github_webhook_validator_github_token_ssm_key" {
  description = "AWS SSM Parameter Store key for sensitive Github personal token used by the Github Webhook Validator Lambda Function"
  type        = string
  default     = null
}

variable "github_webhook_validator_github_token_ssm_description" {
  description = "Github token SSM parameter description"
  type        = string
  default     = "Github token used by Github Webhook Validator Lambda Function"
}

variable "github_webhook_validator_github_token_ssm_value" {
  description = <<EOF
Registered Github webhook token associated with the Github provider. The token will be used by the Github Webhook Validator Lambda Function.
If not provided, module looks for pre-existing SSM parameter via `var.github_webhook_validator_github_token_ssm_key`".
GitHub token needs the `repo` permission to access the private repo. (see more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps)
  EOF
  type        = string
  default     = null
  sensitive   = true
}

variable "github_webhook_validator_github_token_ssm_tags" {
  description = "Tags for Github token SSM parameter"
  type        = map(string)
  default     = {}
}

# STEP-FUNCTION #

variable "step_function_name" {
  description = "Name of AWS Step Function machine"
  type        = string
  default     = "deployment-flow"
}

# RDS #

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

# LAMBDA #

variable "lambda_approval_request_vpc_config" {
  description = <<EOF
VPC configuration for Lambda approval request function.
Ensure that the configuration allows for outgoing HTTPS traffic.
EOF
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "lambda_approval_response_vpc_config" {
  description = <<EOF
VPC configuration for Lambda approval response function.
Ensure that the configuration allows for outgoing HTTPS traffic.
EOF
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "lambda_trigger_sf_vpc_config" {
  description = <<EOF
VPC configuration for Lambda trigger_sf function.
Ensure that the configuration allows for outgoing HTTPS traffic.
EOF
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}