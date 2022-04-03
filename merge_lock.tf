locals {
  merge_lock_dep_zip = "${path.module}/merge_lock_deps.zip"
  merge_lock_dep_dir = "${path.module}/functions/merge_lock/deps"
}

module "github_webhook_validator" {
  source = "github.com/marshall7m/terraform-aws-github-webhook"

  deployment_triggers = {
    approval = filesha1("${path.module}/approval.tf")
  }
  create_github_token_ssm_param = false
  async_lambda_invocation       = true

  github_token_ssm_key = var.github_token_ssm_key
  create_api           = false
  api_id               = aws_api_gateway_rest_api.this.id
  root_resource_id     = aws_api_gateway_rest_api.this.root_resource_id
  execution_arn        = aws_api_gateway_rest_api.this.execution_arn

  stage_name    = var.api_stage_name
  function_name = "${var.step_function_name}-github-webhook-request-validator"

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
            type    = "pr_actions"
            pattern = "(opened|edited|reopened)"
          },
          {
            type    = "file_paths"
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
    GITHUB_TOKEN_SSM_KEY = var.github_token_ssm_key
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.github_token_ssm_access.arn
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