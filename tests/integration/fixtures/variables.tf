variable "testing_integration_github_token" {
  description = "GitHub token used for the Terraform GitHub provider and the PyTest PyGithub API connection"
  type        = string
  sensitive   = true
  default     = null
}

variable "approval_request_sender_email" {
  description = "Email address to use for sending approval requests"
  type        = string
}

variable "testing_secondary_aws_account_id" {
  description = "Secondary AWS account ID used to test module ability to handle multiple AWS accounts"
  type        = number
}

variable "merge_lock_github_token_ssm_value" {
  description = <<EOF
Registered Github webhook token associated with the Github provider. The token will be used by the Merge Lock Lambda Function.
If not provided, module looks for pre-existing SSM parameter via `var.merge_lock_github_token_ssm_key`".
GitHub token only needs the `repo:status` permission. (see more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps)
  EOF
  type        = string
  sensitive   = true
}

variable "github_webhook_validator_github_token_ssm_value" {
  description = <<EOF
Registered Github webhook token associated with the Github provider. The token will be used by the Github Webhook Validator Lambda Function.
If not provided, module looks for pre-existing SSM parameter via `var.github_webhook_validator_github_token_ssm_key`".
If `var.repo_name` is a private repository, the GitHub token needs the `repo` permission to access the private repo.
If `var.repo_name` is a public repository, the GitHub token just needs to be a valid GitHub token registered with the
GitHub provider.
See more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps
  EOF
  type        = string
  sensitive   = true
}

variable "metadb_schema" {
  description = "Schema for AWS RDS Postgres db"
  type        = string
  default     = "prod"
}