locals {
  merge_lock_dep_zip = "${path.module}/merge_lock_deps.zip"
  merge_lock_dep_dir = "${path.module}/functions/merge_lock/deps"
}

module "github_webhook_validator" {
  source = "github.com/marshall7m/terraform-aws-github-webhook"

  deployment_triggers = {
    approval = filesha1("${path.module}/approval.tf")
  }
  create_github_token_ssm_param   = false
  create_api                      = false
  async_lambda_invocation         = true
  github_token_ssm_key            = var.github_token_ssm_key
  api_name                        = aws_api_gateway_rest_api.this.name
  lambda_success_destination_arns = [module.lambda_merge_lock.function_arn]
  repos = [
    {
      name = data.github_repository.this.name
      filter_groups = [
        {
          events     = ["pull_request"]
          pr_actions = ["opened", "edited", "reopened"]
          file_paths = [var.file_path_pattern]
          base_refs  = [var.base_branch]
        }
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
    aws_iam_policy.merge_lock_ssm_param_access.arn
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