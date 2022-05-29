variable "testing_github_token" {
  description = "GitHub token to create testing GitHub repoository and associated webhooks for"
  type        = string
  sensitive   = true
  default     = null
}

variable "testing_sender_email" {
  description = "Email address to use for sending approval requests"
  type        = string
}

variable "testing_secondary_aws_account_id" {
  description = "AWS account ID used to test module ability to handle multiple AWS accounts"
  type        = number
}