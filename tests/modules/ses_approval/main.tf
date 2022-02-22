data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_id
  force_destroy = true
}

resource "aws_s3_bucket_acl" "this" {
  bucket = aws_s3_bucket.this.id
  acl    = "private"
}
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "ses_access" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.ses_access.json
}

data "aws_iam_policy_document" "ses_access" {
  statement {
    sid     = "SESWriteAccess"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.this.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.id]
    }
  }
}

resource "aws_ses_receipt_rule_set" "testing_approval" {
  rule_set_name = var.rule_name
}

resource "aws_ses_receipt_rule" "testing_approval" {
  name          = var.rule_name
  rule_set_name = aws_ses_receipt_rule_set.testing_approval.id
  recipients    = var.recipients
  enabled       = true
  scan_enabled  = false

  s3_action {
    bucket_name       = aws_s3_bucket.this.id
    object_key_prefix = var.key
    position          = 1
  }
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule.testing_approval.name
}
