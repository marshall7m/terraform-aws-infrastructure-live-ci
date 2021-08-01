locals {
  bucket_name = coalesce(var.artifact_bucket_name, lower("${var.step_function_name}-${random_string.artifacts.result}"))
}

resource "random_string" "artifacts" {
  length      = 10
  min_numeric = 5
  special     = false
  lower       = true
  upper       = false
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.bucket_name
  acl           = "private"
  force_destroy = true
  versioning {
    enabled = true
  }
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = var.cmk_arn != null ? var.cmk_arn : data.aws_kms_key.s3.arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
  tags = var.artifact_bucket_tags
  # policy = data.aws_iam_policy_document.artifacts.json
}

#TODO: Figure out policy that allows for aws authorized users/services to put/get objects
# data "aws_iam_policy_document" "artifacts" {
#   statement {
#     sid     = "DenyUnencryptedUploads"
#     effect  = "Deny"
#     actions = ["s3:PutObject"]
#     principals {
#       type        = "AWS"
#       identifiers = ["*"]
#     }
#     resources = ["arn:aws:s3:::${local.bucket_name}/*"]
#     condition {
#       test     = "StringNotEquals"
#       variable = "s3:x-amz-server-side-encryption"
#       values   = ["aws:kms"]
#     }
#   }

#   statement {
#     sid       = "DenyInsecureConnections"
#     effect    = "Deny"
#     actions   = ["s3:*"]
#     resources = ["arn:aws:s3:::${local.bucket_name}/*"]
#     principals {
#       type        = "AWS"
#       identifiers = ["*"]
#     }
#     condition {
#       test     = "Bool"
#       variable = "aws:SecureTransport"
#       values   = ["false"]
#     }
#   }
# }

data "aws_kms_key" "s3" {
  key_id = "alias/aws/s3"
}

resource "aws_s3_bucket_object" "build_scripts" {
  bucket = aws_s3_bucket.artifacts.id
  key    = local.buildspec_scripts_key
  source = "${path.module}/files/utils.sh"
}

resource "aws_s3_bucket_object" "approval_mapping" {
  bucket         = aws_s3_bucket.artifacts.id
  key            = local.approval_mapping_s3_key
  content_base64 = base64encode(format("%v", { for account in var.account_parent_cfg : account.name => account }))
}