variable "account_id" {
  description = "AWS account id"
  type        = number
}

variable "common_tags" {
  description = "Tags to add to all resources"
  type        = map(string)
  default     = {}
}

variable "account_parent_cfg" {
  description = "Any modified child filepath of the parent path will be processed within the parent path associated Map task"
  type = list(object({
    name               = string
    paths              = list(string)
    approval_emails    = list(string)
    min_approval_count = number
  }))
}

variable "terragrunt_parent_dir" {
  description = <<EOF
Parent directory within `var.repo_name` the `module.codebuild_trigger_sf` will run `terragrunt run-all plan` on
to retrieve terragrunt child directories that contain differences within their respective plan. Defaults
to the root of `var.repo_name`
EOF
  type        = string
  default     = "./"
}

variable "base_branch" {
  description = "Base branch for repository that all PRs will compare to"
  type        = string
  default     = "master"
}

variable "role_arn" {
  description = "Pre-existing IAM role ARN to use for the CodePipeline"
  type        = string
  default     = null
}

variable "cmk_arn" {
  description = "ARN of a pre-existing CMK to use for encrypting CodePipeline artifacts at rest"
  type        = string
  default     = null
}

variable "artifact_bucket_name" {
  description = "Name of the artifact S3 bucket to be created or the name of a pre-existing bucket name to be used for storing the pipeline's artifacts"
  type        = string
  default     = null
}

variable "artifact_bucket_force_destroy" {
  description = "Determines if all bucket content will be deleted if the bucket is deleted (error-free bucket deletion)"
  type        = bool
  default     = false
}

variable "artifact_bucket_tags" {
  description = "Tags to attach to provisioned S3 bucket"
  type        = map(string)
  default     = {}
}

# variable "stages" {
#   description = "List of pipeline stages (see: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codepipeline)"
#   type = list(object({
#     name              = string
#     order             = number
#     paths             = list(string)
#     tf_plan_role_arn  = optional(string)
#     tf_apply_role_arn = optional(string)
#   }))
# }

variable "pipeline_tags" {
  description = "Tags to attach to the pipeline"
  type        = map(string)
  default     = {}
}

variable "role_path" {
  description = "Path to create policy"
  default     = "/"
}

variable "role_max_session_duration" {
  description = "Max session duration (seconds) the role can be assumed for"
  default     = 3600
  type        = number
}

variable "role_description" {
  default = "Allows Amazon Codepipeline to call AWS services on your behalf"
}

variable "role_force_detach_policies" {
  description = "Determines attached policies to the CodePipeline service roles should be forcefully detached if the role is destroyed"
  type        = bool
  default     = false
}

variable "role_permissions_boundary" {
  description = "Permission boundary policy ARN used for CodePipeline service role"
  type        = string
  default     = ""
}

variable "role_tags" {
  description = "Tags to add to CodePipeline service role"
  type        = map(string)
  default     = {}
}

# CODESTAR #

variable "codestar_name" {
  description = "AWS CodeStar connection name used to define the source stage of the pipeline"
  type        = string
  default     = null
}

# CODEBUILD #

variable "terra_img" {
  description = "Docker, ECR or AWS CodeBuild managed image to use for Terraform build projects"
  type        = string
  default     = null
}

variable "build_name" {
  description = "CodeBuild project name"
  type        = string
  default     = "infrastructure-live-ci-build"
}

variable "plan_role_name" {
  description = "Name of the IAM role used for running terr* plan commands"
  type        = string
  default     = "infrastructure-live-plan"
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
  default     = "infrastructure-live-apply"
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

variable "build_env_vars" {
  description = "Base environment variables that will be provided for each CodePipeline action build"
  type = list(object({
    name  = string
    value = string
    type  = optional(string)
  }))
  default = []
}

variable "buildspec" {
  description = "CodeBuild buildspec path relative to the source repo root directory"
  type        = string
  default     = null
}

variable "plan_cmd" {
  description = "Terragrunt/Terraform plan command to run on target paths"
  type        = string
  default     = "terragrunt run-all plan"
}

variable "apply_cmd" {
  description = "Terragrunt/Terraform apply command to run on target paths"
  type        = string
  default     = "terragrunt run-all apply -auto-approve"
}

variable "build_tags" {
  description = "Tags to attach to AWS CodeBuild project"
  type        = map(string)
  default     = {}
}

variable "get_rollback_providers_build_name" {
  description = "CodeBuild project name for getting new provider resources to destroy on deployment rollback"
  type        = string
  default     = "infrastructure-live-ci-get-rollback-providers"
}

# GITHUB-WEBHOOK #

variable "repo_name" {
  description = "Name of the GitHub repository"
  type        = string
}

# variable "webhook_filter_groups" {
#   description = "List of webhook filter groups for the Github repository. The GitHub webhook has to pass atleast one filter group in order to proceed to downstream actions"
#   type = list(list(object({
#     pattern                 = string
#     type                    = string
#     exclude_matched_pattern = optional(bool)
#   })))
#   default = []
# }

variable "file_path_pattern" {
  description = "Regex pattern to match webhook modified/new files to. Defaults to any file with `.hcl` or `.tf` extension."
  type        = string
  default     = ".+\\.(hcl|tf)$"
}
variable "api_name" {
  description = "Name of AWS Rest API"
  type        = string
  default     = "infrastructure-live"
}

## SSM ##

### GITHUB-TOKEN ###

variable "github_token_ssm_description" {
  description = "Github token SSM parameter description"
  type        = string
  default     = "Github token used to give read access to the payload validator function to get file that differ between commits" #tfsec:ignore:GEN001
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

variable "cloudwatch_event_name" {
  description = "Name of the CloudWatch event that will monitor the Step Function"
  type        = string
  default     = "infrastructure-live-execution-event"
}

variable "dynamodb_tags" {
  description = "Tags to add to DynamoDB"
  type        = map(string)
  default     = {}
}

variable "queue_pr_build_name" {
  description = "AWS CodeBuild project name for the build that writes to the PR queue table hosted on AWS DynamodB"
  type        = string
  default     = "infrastructure-live-ci-queue-pr"
}

variable "trigger_step_function_build_name" {
  description = "Name of AWS CodeBuild project that will trigger the AWS Step Function"
  type        = string
  default     = "infrastructure-live-ci-trigger-sf"
}

variable "simpledb_name" {
  description = "Name of the AWS SimpleDB domain used for queuing repo PRs"
  type        = string
  default     = "infrastructure-live-ci-PR-queue"
}