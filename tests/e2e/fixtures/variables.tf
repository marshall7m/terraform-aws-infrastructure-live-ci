variable "github_testing_token" {
  description = <<EOF
GitHub token used for the Terraform GitHub provider and the PyTest PyGithub API connection.
The permissions for the token is dependent on if the repo has public or private visibility.
Permissions:
  private:
    - admin:repo_hook
    - repo
    - read:org (if organization repo)
    - delete_repo
    - read:discussion
  public:
    - admin:repo_hook
    - repo:status
    - public_repo
    - read:org (if organization repo)
    - delete_repo
    - read:discussion
See more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps
EOF
  type        = string
  sensitive   = true
  default     = null
}

variable "registry_username" {
  description = "Private Docker registry username used to authenticate docker push to registry"
  type        = string
  default     = "USERNAME"
}

variable "registry_password" {
  description = "Private Docker registry password used to authenticate docker push to registry"
  type        = string
  default     = null
  sensitive   = true
}

variable "full_image_url" {
  description = <<EOF
Private Docker registry to push the Docker image used for the ECS tasks. 
Defaults to using the GitHub registry associated with the testing Github repository
EOF
  type        = string
  default     = null
}

variable "approval_request_sender_email" {
  description = "Email address to use for sending approval requests"
  type        = string
}

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

variable "metadb_schema" {
  description = "Schema for AWS RDS Postgres db"
  type        = string
  default     = "prod"
}