variable "enabled" {
  description = "Determines if module should create resources or destroy pre-existing resources managed by this module"
  type        = bool
  default     = true
}

variable "account_id" {
  description = "AWS account id"
  type        = number
}

variable "common_tags" {
  description = "Tags to add to all resources"
  type        = map(string)
  default     = {}
}

#### CODEPIPELINE ####

variable "branch" {
  description = "Repo branch the pipeline is associated with"
  type        = string
  default     = "master"
}

variable "repo_id" {
  description = "Source repo ID with the following format: owner/repo"
  type        = string
  default     = null
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
  type = string
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

variable "stages" {
  description = "List of pipeline stages (see: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codepipeline)"
  type = list(object({
    name              = string
    order             = number
    paths             = list(string)
    tf_plan_role_arn  = optional(string)
    tf_apply_role_arn = optional(string)
  }))
}

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

#### CODESTAR ####
variable "codestar_name" {
  description = "AWS CodeStar connection name used to define the source stage of the pipeline"
  type = string
  default = null
}

#### CODEBUILD ####

variable "build_name" {
  description = "CodeBuild project name"
  type        = string
  default     = "infrastructure-live-ci"
}

variable "build_assumable_role_arns" {
  description = "AWS ARNs the CodeBuild role can assume"
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
  type = string
  default = "terragrunt run-all plan"
}

variable "apply_cmd" {
  description = "Terragrunt/Terraform apply command to run on target paths"
  type = string
  default = "terragrunt run-all apply -auto-approve"
}

variable "build_tags" {
  description = "Tags to attach to AWS CodeBuild project"
  type        = map(string)
  default     = {}
}