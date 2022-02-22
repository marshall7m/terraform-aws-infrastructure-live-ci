variable "bucket_id" {
  description = "ID of the S3 bucket"
  type        = string
}

variable "rule_name" {
  description = "Name of SES rule set and rule name used to load email objects to bucket"
  type        = string
}

variable "key" {
  description = "S3 bucket key to send approval objects to"
  type        = string
}

variable "recipients" {
  description = "Email addresses that will trigger SES rule"
  type        = list(string)
}