variable "testing_github_token" {
  description = "GitHub token to create testing GitHub repoository and associated webhooks for"
  type        = string
  sensitive   = true
  default     = null
}