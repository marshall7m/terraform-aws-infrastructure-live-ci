data "aws_region" "current" {}

resource "aws_cloudwatch_event_rule" "pipeline" {
  name        = var.cloudwatch_event_name
  description = "Captures pipeline-level events for AWS CodePipeline: ${var.pipeline_name}"

  event_pattern = jsonencode(
    {
      source      = ["aws.codepipeline"]
      detail-type = "CodePipeline Pipeline Execution State Change"
      detail = {
        pipeline = [var.pipeline_name]
        state    = "SUCCEEDED"
      }
    }
  )
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule      = aws_cloudwatch_event_rule.pipeline.name
  target_id = "SendToSF"
  arn       = aws_sfn_state_machine.this.arn
}

resource "aws_sfn_state_machine" "this" {
  name     = var.step_function_name
  role_arn = module.sf_role.role_arn

  definition = jsonencode(
    {
      StartAt = "PollCP"
      states = {
        Type     = "Task"
        Resource = aws_cloudwatch_event_rule.pipeline.arn
      }
      UpdateCP = {
        Type     = "Task"
        Resource = module.update_cp_lambda.function_arn
      }
    }
  )
}

module "sf_role" {
  source           = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name        = var.step_function_name
  trusted_entities = ["states.amazonaws.com"]
  statements = [
    {
      sid       = "LambdaInvokeAccess"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = [module.update_cp_lambda.function_arn]
    },
    {
      sid       = "EventBridgeWriteAccess"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = [aws_cloudwatch_event_rule.pipeline.arn]
    }
  ]
}

module "github_webhook" {
  source = "github.com/marshall7m/terraform-aws-github-webhook"

  create_github_token_ssm_param = var.create_github_token_ssm_param
  github_token_ssm_key          = var.github_token_ssm_key
  api_name                      = var.api_name
  repos = [
    {
      name          = var.repo_name
      filter_groups = var.repo_filter_groups
    }
  ]

  lambda_success_destination_arns = ["arn:aws:lambda:${data.aws_region.current.name}:${var.account_id}:function:${var.trigger_sf_lambda_function_name}"]
}

data "archive_file" "trigger_sf_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/trigger-sf-lambda/function"
  output_path = "${path.module}/trigger_sf_lambda.zip"
}

module "trigger_sf_lambda" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.trigger_sf_lambda.output_path
  source_code_hash = data.archive_file.trigger_sf_lambda.output_base64sha256
  function_name    = var.trigger_sf_lambda_function_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  allowed_to_invoke = [
    {
      statement_id = "LambdaInvokeAccess"
      principal    = "lambda.amazonaws.com"
      arn          = module.github_webhook.function_arn
    }
  ]
  enable_cw_logs = true
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
  statements = [
    {
      sid       = "StepFunctionTriggerAccess"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = [aws_sfn_state_machine.this.arn]
    }
  ]
}

data "archive_file" "update_cp_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/update-cp-lambda/function"
  output_path = "${path.module}/update_cp_lambda.zip"
}

module "update_cp_lambda" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.update_cp_lambda.output_path
  source_code_hash = data.archive_file.update_cp_lambda.output_base64sha256
  function_name    = var.update_cp_lambda_function_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  allowed_to_invoke = [
    {
      statement_id = "StepFunctionInvokeAccess"
      principal    = "stepfunction.amazonaws.com"
      arn          = aws_sfn_state_machine.this.arn
    }
  ]
  enable_cw_logs = true
  env_vars = {
    GITHUB_TOKEN_SSM_KEY = var.github_token_ssm_key
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]

  statements = [
    {
      sid    = "GithubWebhookTokenReadAccess"
      effect = "Allow"
      actions = [
        "ssm:GetParameter"
      ]
      resources = [module.github_webhook.github_token_ssm_arn]
    },
    {
      sid       = "SSMDecryptAccess"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [data.aws_kms_key.ssm.arn]
    },
    {
      sid       = "CodePipelineTriggerAccess"
      effect    = "Allow"
      actions   = ["codepipeline:StartPipelineExecution"]
      resources = [module.codepipeline.arn]
    }
  ]

  lambda_layers = [
    {
      filename         = module.github_webhook.lambda_deps.output_path
      name             = "update-stages"
      runtimes         = ["python3.8"]
      source_code_hash = module.github_webhook.lambda_deps.output_base64sha256
      description      = "Shared dependencies between lambda function: ${var.update_cp_lambda_function_name} and lambda function: ${module.github_webhook.function_name}"
    }
  ]
}

data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}
