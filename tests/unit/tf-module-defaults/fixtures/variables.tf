variable "testing_github_token" {
  description = "GitHub token to create testing GitHub repoository and associated webhooks for"
  type        = string
  sensitive   = true
  default     = null
}

variable "repo_name" {
  description = "Name of the GitHub repository that is owned by the Github provider"
  type        = string
  default     = ""
}