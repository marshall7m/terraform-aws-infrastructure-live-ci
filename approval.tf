locals {
  approval_request_name = "${var.prefix}-request"

  approval_response_name    = "${var.prefix}-response"
  approval_response_context = "${path.module}/functions/approval_response"

  approval_logs                 = "${var.prefix}-approval"
  approval_sender_arn           = try(aws_ses_email_identity.approval[0].arn, data.aws_ses_email_identity.approval[0].arn, var.approval_sender_arn)
  ses_approval_subject_template = "Approval Request: {{execution_name}}"
}

resource "aws_sns_topic" "approval" {
  name = "${var.prefix}-approval-request"
}

resource "aws_sns_topic_subscription" "ses_approval_request" {
  topic_arn = aws_sns_topic.approval.arn
  protocol  = "lambda"
  endpoint  = module.lambda_approval_request.lambda_function_arn
}

data "aws_iam_policy_document" "lambda_approval_request" {
  statement {
    sid    = "SESAccess"
    effect = "Allow"
    actions = [
      "ses:SendBulkTemplatedEmail"
    ]
    resources = [aws_ses_template.approval.arn]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.approval_request_sender_email]
    }

    condition {
      test     = "ForAllValues:StringLike"
      variable = "ses:Recipients"
      values   = flatten([for account in var.account_parent_cfg : account.voters])
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter"
    ]
    resources = [aws_ssm_parameter.email_approval_secret.arn]
  }
}

resource "aws_iam_policy" "lambda_approval_request" {
  name        = "${local.approval_request_name}-ses-access"
  description = "Allows Lambda function to send SES emails to and from defined email addresses"
  policy      = data.aws_iam_policy_document.lambda_approval_request.json
}

resource "random_password" "email_approval_secret" {
  length = 24
}

resource "aws_ssm_parameter" "email_approval_secret" {
  name  = "${var.prefix}-email-approval-secret"
  type  = "SecureString"
  value = random_password.email_approval_secret.result
}

module "lambda_approval_request" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "3.3.1"

  function_name = local.approval_request_name
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  source_path = [
    "${path.module}/functions/approval_request",
    {
      path          = "${path.module}/functions/common_lambda"
      prefix_in_zip = "common_lambda"
    }
  ]

  environment_variables = {
    SENDER_EMAIL_ADDRESS          = var.approval_request_sender_email
    SES_TEMPLATE                  = aws_ses_template.approval.name
    EMAIL_APPROVAL_SECRET_SSM_KEY = aws_ssm_parameter.email_approval_secret.name
  }
  allowed_triggers = {
    SNSInvokeAccess = {
      service    = "sns"
      source_arn = aws_sns_topic.approval.arn
    }
  }
  create_unqualified_alias_allowed_triggers = true
  publish                                   = true
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.lambda_approval_request.arn
  ]
  attach_policies               = true
  number_of_policies            = 2
  role_force_detach_policies    = true
  attach_cloudwatch_logs_policy = true

  vpc_subnet_ids         = try(var.lambda_approval_request_vpc_config.subnet_ids, null)
  vpc_security_group_ids = try(var.lambda_approval_request_vpc_config.security_group_ids, null)
  attach_network_policy  = var.lambda_approval_request_vpc_config != null ? true : false
}

data "aws_iam_policy_document" "approval_response" {
  statement {
    effect    = "Allow"
    actions   = ["states:SendTaskSuccess"]
    resources = [aws_sfn_state_machine.this.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["states:DescribeExecution"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter"
    ]
    resources = [aws_ssm_parameter.email_approval_secret.arn]
  }
}
resource "aws_iam_policy" "approval_response" {
  name        = "${local.approval_response_name}-sf-access"
  description = "Allows Lambda function to describe Step Function executions and send success task tokens to associated Step Function machine"
  policy      = data.aws_iam_policy_document.approval_response.json
}

module "ecr_approval_response" {
  count                   = var.approval_response_image_address == null ? 1 : 0
  source                  = "terraform-aws-modules/ecr/aws"
  version                 = "1.5.0"
  repository_name         = "${var.prefix}/approval-response"
  repository_force_delete = true
  repository_type         = "private"
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 5 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 5
        },
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "docker_image" "ecr_approval_response" {
  count        = var.approval_response_image_address == null ? 1 : 0
  name         = "${module.ecr_approval_response[0].repository_url}:${local.module_docker_img_tag}"
  keep_locally = true
  build {
    path     = local.approval_response_context
    no_cache = true
  }
  triggers = { for f in fileset(local.approval_response_context, "**") :
  f => filesha256(format("${local.approval_response_context}/%s", f)) }
}

resource "docker_tag" "ecr_approval_response" {
  count        = var.approval_response_image_address == null ? 1 : 0
  source_image = docker_image.ecr_approval_response[0].image_id
  target_image = "${module.ecr_approval_response[0].repository_url}:${local.module_docker_img_tag}-${split(":", docker_image.ecr_approval_response[0].image_id)[1]}"
}

resource "docker_registry_image" "ecr_approval_response" {
  count = var.approval_response_image_address == null ? 1 : 0
  name  = docker_tag.ecr_approval_response[0].target_image
}

module "lambda_approval_response" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "3.3.1"

  function_name = local.approval_response_name
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  image_uri      = try(docker_registry_image.ecr_approval_response[0].name, var.approval_response_image_address)
  create_package = false
  package_type   = "Image"
  architectures  = ["x86_64"]

  timeout = 180
  environment_variables = {
    METADB_NAME                   = local.metadb_name
    AURORA_CLUSTER_ARN            = aws_rds_cluster.metadb.arn
    AURORA_SECRET_ARN             = aws_secretsmanager_secret_version.ci_metadb_user.arn
    EMAIL_APPROVAL_SECRET_SSM_KEY = aws_ssm_parameter.email_approval_secret.name
  }

  authorization_type         = "NONE"
  create_lambda_function_url = true

  publish = true

  attach_policies               = true
  number_of_policies            = 3
  role_force_detach_policies    = true
  attach_cloudwatch_logs_policy = true
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.approval_response.arn
  ]
  vpc_subnet_ids         = try(var.lambda_approval_response_vpc_config.subnet_ids, null)
  vpc_security_group_ids = try(var.lambda_approval_response_vpc_config.security_group_ids, null)
  attach_network_policy  = var.lambda_approval_response_vpc_config != null ? true : false
}

data "aws_ses_email_identity" "approval" {
  count = var.send_verification_email == false && var.approval_sender_arn == null ? 1 : 0
  email = var.approval_request_sender_email
}

resource "aws_ses_email_identity" "approval" {
  count = var.send_verification_email ? 1 : 0
  email = var.approval_request_sender_email
}

data "aws_iam_policy_document" "approval" {
  statement {
    actions   = ["ses:SendEmail", "ses:SendBulkTemplatedEmail"]
    resources = [local.approval_sender_arn]

    principals {
      identifiers = ["*"]
      type        = "AWS"
    }
  }
}

resource "aws_ses_identity_policy" "approval" {
  count    = var.create_approval_sender_policy ? 1 : 0
  identity = local.approval_sender_arn
  name     = "${var.prefix}-approval"
  policy   = data.aws_iam_policy_document.approval.json
}

resource "aws_ses_template" "approval" {
  name    = local.approval_request_name
  subject = local.ses_approval_subject_template
  html    = file("${path.module}/approval_template.html")
}