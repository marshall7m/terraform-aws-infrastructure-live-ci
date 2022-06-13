locals {
  merge_lock_dep_zip              = "${path.module}/merge_lock_deps.zip"
  merge_lock_dep_dir              = "${path.module}/functions/merge_lock/deps"
  merge_lock_github_token_ssm_key = coalesce(var.merge_lock_github_token_ssm_key, "${local.merge_lock_name}-github-token")
}

data "aws_ssm_parameter" "merge_lock_github_token" {
  count = var.create_merge_lock_github_token_ssm_param != true ? 1 : 0
  name  = local.merge_lock_github_token_ssm_key
}

resource "aws_ssm_parameter" "merge_lock_github_token" {
  count       = var.create_merge_lock_github_token_ssm_param ? 1 : 0
  name        = local.merge_lock_github_token_ssm_key
  description = var.merge_lock_github_token_ssm_description
  type        = "SecureString"
  value       = var.merge_lock_github_token_ssm_value
}

module "github_webhook_validator" {
  source = "github.com/marshall7m/terraform-aws-github-webhook"

  deployment_triggers = {
    approval = filesha1("${path.module}/approval.tf")
  }
  async_lambda_invocation = true

  create_api       = false
  api_id           = aws_api_gateway_rest_api.this.id
  root_resource_id = aws_api_gateway_rest_api.this.root_resource_id
  execution_arn    = aws_api_gateway_rest_api.this.execution_arn

  stage_name    = var.api_stage_name
  function_name = "${var.prefix}-${var.step_function_name}-github-webhook-request-validator"

  includes_private_repo  = true
  github_token_ssm_value = var.github_webhook_validator_github_token_ssm_value

  lambda_success_destination_arns = [module.lambda_merge_lock.function_arn]
  repos = [
    {
      name = var.repo_name
      filter_groups = [
        [
          {
            type    = "event"
            pattern = "pull_request"
          },
          {
            type    = "pr_action"
            pattern = "(opened|edited|reopened)"
          },
          {
            type    = "file_path"
            pattern = var.file_path_pattern
          },
          {
            type    = "base_ref"
            pattern = var.base_branch
          }
        ]
      ]
    }
  ]
  # approval api resources needs to be created before this module since the module manages the deployment of the api
  depends_on = [
    aws_api_gateway_resource.approval,
    aws_api_gateway_integration.approval,
    aws_api_gateway_method.approval
  ]
}

data "archive_file" "lambda_merge_lock" {
  type        = "zip"
  source_dir  = "${path.module}/functions/merge_lock"
  output_path = "${path.module}/merge_lock.zip"
}

resource "null_resource" "lambda_merge_lock_deps" {
  triggers = {
    zip_hash = fileexists(local.merge_lock_dep_zip) ? 0 : timestamp()
  }
  provisioner "local-exec" {
    command = "pip install --target ${local.merge_lock_dep_dir}/python requests==2.27.1"
  }
}

data "archive_file" "lambda_merge_lock_deps" {
  type        = "zip"
  source_dir  = local.merge_lock_dep_dir
  output_path = local.merge_lock_dep_zip
  depends_on = [
    null_resource.lambda_merge_lock_deps
  ]
}

module "lambda_merge_lock" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_merge_lock.output_path
  source_code_hash = data.archive_file.lambda_merge_lock.output_base64sha256
  function_name    = local.merge_lock_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  env_vars = {
    MERGE_LOCK_SSM_KEY   = aws_ssm_parameter.merge_lock.name
    GITHUB_TOKEN_SSM_KEY = local.merge_lock_github_token_ssm_key
    STATUS_CHECK_NAME    = var.merge_lock_status_check_name
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.merge_lock_github_token_ssm_read_access.arn
  ]
  statements = [
    {
      effect    = "Allow"
      actions   = ["ssm:DescribeParameters"]
      resources = ["*"]
    },
    {
      sid       = "SSMParamMergeLockReadAccess"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = [aws_ssm_parameter.merge_lock.arn]
    }
  ]
  lambda_layers = [
    {
      filename         = data.archive_file.lambda_merge_lock_deps.output_path
      name             = "${local.merge_lock_name}-deps"
      runtimes         = ["python3.8"]
      source_code_hash = data.archive_file.lambda_merge_lock_deps.output_base64sha256
      description      = "Dependencies for lambda function: ${local.merge_lock_name}"
    }
  ]
}

resource "github_branch_protection" "merge_lock" {
  count         = var.enable_branch_protection ? 1 : 0
  repository_id = var.repo_name

  pattern          = var.base_branch
  enforce_admins   = var.enforce_admin_branch_protection
  allows_deletions = true

  required_status_checks {
    strict   = false
    contexts = [var.merge_lock_status_check_name, var.pr_plan_status_check_name]
  }

  dynamic "required_pull_request_reviews" {
    for_each = var.pr_approval_count != null ? [1] : []
    content {
      dismiss_stale_reviews           = true
      required_approving_review_count = var.pr_approval_count
    }
  }
}