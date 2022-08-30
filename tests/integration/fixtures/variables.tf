variable "testing_integration_github_token" {
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

variable "mut_id" {
  description = "Module Under Testing ID"
  type        = string
}

variable "metadb_username" {
  description = "Master username of the metadb"
  type        = string
  default     = "root"
}