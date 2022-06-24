locals {
  merge_lock_name     = "${var.prefix}-merge-lock"
  merge_lock_deps_zip = "${path.module}/merge_lock_deps.zip"
  merge_lock_deps_dir = "${path.module}/functions/merge_lock/deps"

  trigger_pr_plan_name     = "${var.prefix}-trigger-pr-plan"
  trigger_pr_plan_deps_zip = "${path.module}/trigger_pr_plan_deps.zip"
  trigger_pr_plan_deps_dir = "${path.module}/functions/trigger_pr_plan/deps"

  github_webhook_validator_function_name = "${var.prefix}-webhook-validator"
}

module "github_webhook_validator" {
  source = "github.com/marshall7m/terraform-aws-github-webhook?ref=v0.1.0"

  deployment_triggers = {
    approval = filesha1("${path.module}/approval.tf")
  }
  async_lambda_invocation = true

  create_api       = false
  api_id           = aws_api_gateway_rest_api.this.id
  root_resource_id = aws_api_gateway_rest_api.this.root_resource_id
  execution_arn    = aws_api_gateway_rest_api.this.execution_arn

  stage_name    = var.api_stage_name
  function_name = local.github_webhook_validator_function_name

  includes_private_repo = true
  github_token_ssm_key  = local.github_token_ssm_key

  github_secret_ssm_key = "${local.github_webhook_validator_function_name}-secret"

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

resource "aws_ssm_parameter" "merge_lock" {
  name        = local.merge_lock_name
  description = "Locks PRs with infrastructure changes from being merged into base branch"
  type        = "String"
  value       = "none"
}


data "archive_file" "lambda_merge_lock" {
  type        = "zip"
  source_dir  = "${path.module}/functions/merge_lock"
  output_path = "${path.module}/merge_lock.zip"
}

resource "null_resource" "lambda_merge_lock_deps" {
  triggers = {
    zip_hash = fileexists(local.merge_lock_deps_zip) ? 0 : timestamp()
  }
  provisioner "local-exec" {
    command = "pip install --target ${local.merge_lock_deps_dir}/python requests==2.27.1"
  }
}

data "archive_file" "lambda_merge_lock_deps" {
  type        = "zip"
  source_dir  = local.merge_lock_deps_dir
  output_path = local.merge_lock_deps_zip
  depends_on = [
    null_resource.lambda_merge_lock_deps
  ]
}


module "lambda_merge_lock" {
  source           = "github.com/marshall7m/terraform-aws-lambda?ref=v0.1.4"
  filename         = data.archive_file.lambda_merge_lock.output_path
  source_code_hash = data.archive_file.lambda_merge_lock.output_base64sha256
  function_name    = local.merge_lock_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  env_vars = {
    MERGE_LOCK_SSM_KEY   = aws_ssm_parameter.merge_lock.name
    GITHUB_TOKEN_SSM_KEY = local.github_token_ssm_key
    STATUS_CHECK_NAME    = var.merge_lock_status_check_name
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.github_token_ssm_read_access.arn
  ]
  enable_destinations     = true
  success_destination_arn = module.lambda_trigger_pr_plan.function_arn
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

data "archive_file" "lambda_trigger_pr_plan" {
  type        = "zip"
  source_dir  = "${path.module}/functions/trigger_pr_plan"
  output_path = "${path.module}/trigger_pr_plan.zip"
}

resource "null_resource" "lambda_trigger_pr_plan_deps" {
  triggers = {
    zip_hash = fileexists(local.trigger_pr_plan_deps_zip) ? 0 : timestamp()
  }
  provisioner "local-exec" {
    command = "pip install --target ${local.trigger_pr_plan_deps_dir}/python requests==2.27.1"
  }
}

data "archive_file" "lambda_trigger_pr_plan_deps" {
  type        = "zip"
  source_dir  = local.trigger_pr_plan_deps_dir
  output_path = local.trigger_pr_plan_deps_zip
  depends_on = [
    null_resource.lambda_trigger_pr_plan_deps
  ]
}

module "lambda_trigger_pr_plan" {
  source           = "github.com/marshall7m/terraform-aws-lambda?ref=v0.1.4"
  filename         = data.archive_file.lambda_trigger_pr_plan.output_path
  source_code_hash = data.archive_file.lambda_trigger_pr_plan.output_base64sha256
  function_name    = local.trigger_pr_plan_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  env_vars = {
    GITHUB_TOKEN_SSM_KEY = local.github_token_ssm_key
    ECS_CLUSTER_ARN      = aws_ecs_cluster.this.arn
    ACCOUNT_DIM          = jsonencode(var.account_parent_cfg)
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
  statements = [
    {
      effect = "Allow"
      actions = [
        "ecs:RunTask"
      ]
      conditions = [
        {
          test     = "ArnEquals"
          variable = "ecs:cluster"
          values   = [aws_ecs_cluster.this.arn]
        }
      ]
      resources = [
        aws_ecs_task_definition.plan.arn
      ]
    }
  ]
  lambda_layers = [
    {
      filename         = data.archive_file.lambda_trigger_pr_plan_deps.output_path
      name             = "${local.trigger_pr_plan_name}-deps"
      runtimes         = ["python3.8"]
      source_code_hash = data.archive_file.lambda_trigger_pr_plan_deps.output_base64sha256
      description      = "Dependencies for lambda function: ${local.trigger_pr_plan_name}"
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
    contexts = [var.merge_lock_status_check_name]
  }

  dynamic "required_pull_request_reviews" {
    for_each = var.pr_approval_count != null ? [1] : []
    content {
      dismiss_stale_reviews           = true
      required_approving_review_count = var.pr_approval_count
    }
  }
}