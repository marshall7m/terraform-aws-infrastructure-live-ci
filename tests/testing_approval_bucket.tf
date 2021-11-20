locals {
  testing_email_s3_key = "emails/"
}
resource "aws_s3_bucket" "testing" {
  bucket        = local.mut_id
  acl           = "private"
  force_destroy = true
  versioning {
    enabled = true
  }
}

resource "aws_s3_bucket_policy" "ses_access" {
  bucket = aws_s3_bucket.testing.id
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
    resources = ["${aws_s3_bucket.testing.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.id]
    }
  }
}

data "aws_iam_policy_document" "testing_bucket_read_access" {
  statement {
    sid    = "GetS3Objects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetObjectVersion"
    ]
    resources = [
      aws_s3_bucket.testing.arn,
      "${aws_s3_bucket.testing.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "testing_bucket_read_access" {
  name        = "${local.mut_id}-read-access"
  description = "Allows read access to SES approval request emails"
  policy      = data.aws_iam_policy_document.testing_bucket_read_access.json
}

data "archive_file" "lambda_testing_approval" {
  type        = "zip"
  source_dir  = "${path.module}/functions"
  output_path = "${path.module}/testing_approval.zip"
}

module "lambda_testing_approval" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_testing_approval.output_path
  source_code_hash = data.archive_file.lambda_testing_approval.output_base64sha256
  function_name    = "${local.mut_id}-testing"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  allowed_to_invoke = [
    {
      principal = "ses.amazonaws.com"
    }
  ]
  env_vars = {
    TESTING_BUCKET_NAME  = aws_s3_bucket.testing.id
    TESTING_EMAIL_S3_KEY = local.testing_email_s3_key
  }

  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.testing_bucket_read_access.arn
  ]
}

resource "aws_ses_receipt_rule_set" "testing_approval" {
  rule_set_name = "approval-rule-set"
}

resource "aws_ses_receipt_rule" "testing_approval" {
  name          = "${local.mut_id}-approval"
  rule_set_name = aws_ses_receipt_rule_set.testing_approval.id
  recipients    = ["success@simulator.amazonses.com"]
  enabled       = true
  scan_enabled  = false

  s3_action {
    bucket_name       = aws_s3_bucket.testing.id
    object_key_prefix = local.testing_email_s3_key
    position          = 1
  }

  lambda_action {
    function_arn    = module.lambda_testing_approval.function_arn
    invocation_type = "Event"
    position        = 2
  }
}
