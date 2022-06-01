variable "testing_github_token" {
  description = "GitHub token used for the Terraform GitHub provider and the PyTest PyGithub API connection"
  type        = string
  sensitive   = true
  default     = null
}

variable "repo_name" {
  description = "Name of the GitHub repository that is owned by the Github provider"
  type        = string
}