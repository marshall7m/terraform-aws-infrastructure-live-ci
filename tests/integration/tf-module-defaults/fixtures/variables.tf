variable "testing_unit_github_token" {
  description = <<EOF
GitHub token used for the Terraform GitHub provider and the PyTest PyGithub API connection.
The permissions for the token is dependent on if the repo has public or private visibility.
Permissions:
  private:
    - repo
    - delete_repo
  public:
    - public_repo
    - delete_repo
See more about OAuth scopes here: https://docs.github.com/en/developers/apps/building-oauth-apps/scopes-for-oauth-apps
EOF
  type        = string
  sensitive   = true
  default     = null
}

variable "repo_name" {
  description = "Name of the GitHub repository that is owned by the Github provider"
  type        = string
}