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
  - apply_role_arn: IAM role ARN within the account that the deploy build will assume
    - Fine-grained permissions for each Terragrunt directory within the account can be used by defining a before_hook block that
      conditionally defines that assume_role block within the directory dependant on the Terragrunt command. For example within `prod/iam/terragrunt.hcl`,
      define a before hook block that passes a strict read-only role ARN for `terragrunt plan` commands and a strict write role ARN for `terragrunt apply`. Then
      within the `apply_role_arn` attribute here, define a IAM role that can assume both of these roles.
EOF
  type = list(object({
    name                = string
    path                = string
    voters              = list(string)
    min_approval_count  = number
    min_rejection_count = number
    dependencies        = list(string)
    plan_role_arn       = string
    apply_role_arn      = string
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


variable "plan_cpu" {
  description = <<EOF
Number of CPU units the PR plan task will use. 
See for more info: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
EOF
  type        = number
  default     = 256
}

variable "plan_memory" {
  description = <<EOF
Amount of memory (MiB) the PR plan task will use. 
See for more info: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
EOF
  type        = string
  default     = 512
}

variable "ecs_subnet_ids" {
  description = <<EOF
AWS VPC subnet IDs to host the ECS container instances within.
The subnets should allow the ECS containers to have internet access to pull the
container image and make API calls to Terraform provider resources.
The subnets should be associated with the VPC ID specified under `var.vpc_id`
EOF
  type        = list(string)
}

variable "ecs_assign_public_ip" {
  description = <<EOF
Determines if an public IP address will be associated with ECS tasks.
Value is required to be `true` if var.ecs_subnet_ids are public subnets.
Value can be `false` if var.ecs_subnet_ids are private subnets that have a route
to a NAT gateway.
EOF
  type        = bool
  default     = false
}
variable "vpc_id" {
  description = <<EOF
AWS VPC ID to host the ECS container instances within.
The VPC should be associated with the subnet IDs specified under `var.ecs_subnet_ids`
EOF
  type        = string
}

variable "ecs_task_logs_retention_in_days" {
  description = "Number of days the ECS task logs will be retained"
  type        = number
  default     = 14
}

variable "pr_plan_env_vars" {
  description = "Environment variables that will be provided to open PR's Terraform planning tasks"
  type = list(object({
    name  = string
    value = string
    type  = optional(string)
  }))
  default = []
}

variable "ecs_image_address" {
  description = <<EOF
Docker registry image to use for the ECS Fargate containers. If not specified, this Terraform module's GitHub registry image
will be used with the tag associated with the version of this module. 
EOF
  type        = string
  default     = null
}

variable "tf_state_read_access_policy" {
  description = "AWS IAM policy ARN that allows create deploy stack ECS task to read from Terraform remote state resource"
  type        = string
}

variable "terraform_version" {
  description = <<EOF
Terraform version used for create_deploy_stack and terra_run tasks.
Version must be >= `0.13.0`.
If repo contains a variety of version constraints, implementing a 
version manager is recommended (e.g. tfenv).
EOF
  type        = string
  default     = ""
}

variable "terragrunt_version" {
  description = <<EOF
Terragrunt version used for create_deploy_stack and terra_run tasks.
Version must be >= `0.31.0`.
If repo contains a variety of version constraints, implementing a 
version manager is recommended (e.g. tgswitch).
EOF
  type        = string
  default     = ""
}

variable "terra_run_env_vars" {
  description = "Environment variables that will be provided for tf plan/apply tasks"
  type = list(object({
    name  = string
    value = string
    type  = optional(string)
  }))
  default = []
}
variable "terra_run_cpu" {
  description = <<EOF
Number of CPU units the terra run task will use. 
See for more info: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
EOF
  type        = number
  default     = 256
}

variable "terra_run_memory" {
  description = <<EOF
Amount of memory (MiB) the terra run task will use. 
See for more info: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
EOF
  type        = string
  default     = 512
}

variable "create_deploy_stack_scan_type" {
  description = <<EOF
If set to `graph`, the create_deploy_stack build will use the git detected differences to determine what directories to run Step Function executions for.
If set to `plan`, the build will use terragrunt run-all plan detected differences to determine the executions.
Set to `plan` if changes to the terraform resources are also being controlled outside of the repository (e.g AWS console, separate CI pipeline, etc.)
which results in need to refresh the terraform remote state to accurately detect changes.
Otherwise set to `graph`, given that collecting changes via git will be significantly faster than collecting changes via terragrunt run-all plan.
EOF
  type        = string
  default     = "graph"
}

variable "ecs_tasks_common_env_vars" {
  description = "Common env vars defined within all ECS tasks. Useful for setting Terragrunt specific env vars required to run Terragrunt commands."
  type = list(object({
    name  = string
    value = string
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
  default     = "CreateDeployStack"
}

variable "create_deploy_stack_cpu" {
  description = <<EOF
Number of CPU units the create deploy stack task will use. 
See for more info: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
EOF
  type        = number
  default     = 256
}

variable "create_deploy_stack_memory" {
  description = <<EOF
Amount of memory (MiB) the create deploy stack task will use. 
See for more info: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
EOF
  type        = string
  default     = 512
}

# GITHUB WEBHOOK #

variable "repo_clone_url" {
  description = "Clone URL of the repository (e.g. ssh://host.xz/path/to/repo.git, https://host.xz/path/to/repo.git)"
  type        = string
}

variable "file_path_pattern" {
  description = "Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension."
  type        = string
  default     = <<EOF
.+\.(hcl|tf)$
EOF
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

variable "create_github_token_ssm_param" {
  description = "Determines if a AWS SSM Parameter Store value should be created for the GitHub token"
  type        = bool
}

variable "github_token_ssm_key" {
  description = "AWS SSM Parameter Store key for sensitive Github personal token used by the Merge Lock Lambda Function"
  type        = string
  default     = null
}

variable "github_token_ssm_description" {
  description = "Github token SSM parameter description"
  type        = string
  default     = "Github token used by Merge Lock Lambda Function"
}

variable "github_token_ssm_value" {
  description = <<EOF
Registered Github webhook token associated with the Github provider. The token will be used by the Merge Lock Lambda Function.
If not provided, module looks for pre-existing SSM parameter via `var.github_token_ssm_key`".
GitHub token needs the `repo` permission to send commit statuses for private repos. (see more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps)
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
  description = "Additional AWS VPC security group to associate the metadb with"
  type        = list(string)
  default     = []
}

variable "metadb_subnet_ids" {
  description = "AWS VPC subnet IDs to host the metadb within"
  type        = list(string)
}

variable "metadb_availability_zones" {
  description = "AWS availability zones that the metadb RDS cluster will be hosted in. Recommended to define atleast 3 zones."
  type        = list(string)
  default     = null
}

variable "metadb_ci_username" {
  description = "Name of the metadb user used for the ECS tasks"
  type        = string
  default     = "ci_user"
}

variable "metadb_ci_password" {
  description = "Password for the metadb user used for the ECS tasks"
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

variable "approval_response_image_address" {
  description = <<EOF
Docker registry image to use for the approval repsonse Lambda Function. If not specified, this Terraform module's GitHub registry image
will be used with the tag associated with the version of this module. 
EOF
  type        = string
  default     = null
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

variable "lambda_webhook_receiver_vpc_config" {
  description = <<EOF
VPC configuration for Lambda webhook_receiver function.
Ensure that the configuration allows for outgoing HTTPS traffic.
EOF
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "webhook_receiver_image_address" {
  description = <<EOF
Docker registry image to use for the webhook receiver Lambda Function. If not specified, this Terraform module's GitHub registry image
will be used with the tag associated with the version of this module. 
EOF
  type        = string
  default     = null
}

variable "private_registry_auth" {
  description = "Determines if authentification is required to pull the docker images used by the ECS tasks"
  type        = bool
  default     = false
}

variable "create_private_registry_secret" {
  description = "Determines if the module should create the AWS Secret Manager resource used for private registry authentification"
  type        = bool
  default     = true
}

variable "registry_username" {
  description = "Private Docker registry username used to authenticate ECS task to pull docker image"
  type        = string
  default     = null
}

variable "registry_password" {
  description = "Private Docker registry password used to authenticate ECS task to pull docker image"
  type        = string
  default     = null
  sensitive   = true
}

variable "private_registry_secret_manager_arn" {
  description = "Pre-existing AWS Secret Manager ARN used for private registry authentification"
  type        = string
  default     = null
}

variable "private_registry_custom_kms_key_arn" {
  description = "ARN of the custom AWS KMS key to use for decrypting private registry credentials hosted with AWS Secret Manager"
  type        = string
  default     = null
}


variable "commit_status_config" {
  description = <<EOF
Determines which commit statuses should be sent for each of the specified pipeline components. 
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
    PrPlan            = optional(bool, true)
    CreateDeployStack = optional(bool, true)
    Plan              = optional(bool, true)
    Apply             = optional(bool, true)
    Execution         = optional(bool, true)
  })
  default = {}
}


variable "approval_sender_arn" {
  description = "AWS SES identity ARN used to send approval emails"
  type        = string
  default     = null
}


variable "create_metadb_subnet_group" {
  description = "Determines if a AWS RDS subnet group should be created for the metadb"
  type        = bool
  default     = false
}

variable "create_approval_sender_policy" {
  description = "Determines if an identity policy should be attached to approval sender identity"
  type        = bool
  default     = true
}

variable "metadb_endpoint_url" {
  description = "Endpoint URL that metadb setup queries will be directed to (used for local metadb testing)"
  type        = string
  default     = null
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

variable "metadb_name" {
  description = "Name of the metadb"
  type        = string
  default     = null
}