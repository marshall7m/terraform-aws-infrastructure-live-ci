variable "account_id" {
  description = "AWS account id"
  type        = number
}

variable "common_tags" {
  description = "Tags to add to all resources"
  type        = map(string)
  default     = {}
}

# CODEPIPELINE #

variable "stage_parent_paths" {
  description = "Parent directory path for each CodePipeline stage. Any modified child filepath of the parent path will be processed within the parent path associated stage"
  type        = list(string)
}

variable "branch" {
  description = "Repo branch the pipeline is associated with"
  type        = string
  default     = "master"
}

variable "role_arn" {
  description = "Pre-existing IAM role ARN to use for the CodePipeline"
  type        = string
  default     = null
}

variable "pipeline_name" {
  description = "Pipeline name"
  type        = string
  default     = "infrastructure-live-ci-pipeline"
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

variable "build_name" {
  description = "CodeBuild project name"
  type        = string
  default     = "infrastructure-live-ci"
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

# GITHUB-WEBHOOK #

variable "repo_name" {
  description = "Name of the GitHub repository"
  type        = string
}

variable "repo_filter_groups" {
  description = "List of filter groups for the Github repository. The GitHub webhook request has to pass atleast one filter group in order to proceed to downstream actions"
  type = list(object({
    events                 = list(string)
    pr_actions             = optional(list(string))
    base_refs              = optional(list(string))
    head_refs              = optional(list(string))
    actor_account_ids      = optional(list(string))
    commit_messages        = optional(list(string))
    file_paths             = optional(list(string))
    exclude_matched_filter = optional(bool)
  }))
}

variable "api_name" {
  description = "Name of AWS Rest API"
  type        = string
  default     = "terraform-infrastructure-live"
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

### GITHUB-SECRET ###

variable "github_secret_ssm_key" {
  description = "Key for github secret within AWS SSM Parameter Store"
  type        = string
  default     = "github-webhook-github-secret" #tfsec:ignore:GEN001
}

variable "github_secret_ssm_description" {
  description = "Github secret SSM parameter description"
  type        = string
  default     = "Secret value for Github Webhooks" #tfsec:ignore:GEN001
}

variable "github_secret_ssm_tags" {
  description = "Tags for Github webhook secret SSM parameter"
  type        = map(string)
  default     = {}
}

# STEP-FUNCTION #

variable "step_function_name" {
  description = "Name of AWS Step Function machine"
  type        = string
  default     = "infrastructure-live-step-function"
}

variable "trigger_sf_lambda_function_name" {
  description = "Name of the AWS Lambda function that will trigger a Step Function execution"
  type        = string
  default     = "infrastructure-live-step-function-trigger"
}

variable "update_cp_lambda_function_name" {
  description = "Name of the AWS Lambda function that will dynamically update AWS CodePipeline stages based on commit changes to the repository"
  type        = string
  default     = "infrastructure-live-update-cp-stages"
}

variable "cloudwatch_event_name" {
  description = "Name of the CloudWatch event that will monitor the CodePipeline"
  type        = string
  default     = "infrastructure-live-cp-execution-event"
}