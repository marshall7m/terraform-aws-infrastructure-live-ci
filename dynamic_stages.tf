data "aws_region" "current" {}

resource "aws_cloudwatch_event_rule" "this" {
  name        = var.cloudwatch_event_name
  description = "Captures execution-level events for AWS Step Function: ${var.step_function_name}"

  event_pattern = jsonencode(
    {
      source      = ["aws.states"]
      detail-type = ["Step Functions Execution Status Change"]
      detail = {
        executionArn = [aws_sfn_state_machine.this.arn]
        state        = ["SUCCEEDED"]
      }
    }
  )
}

resource "aws_cloudwatch_event_target" "sf" {
  rule      = aws_cloudwatch_event_rule.this.name
  target_id = "Send"
  arn       = module.lambda_trigger_sf.function_arn
  role_arn  = module.cw_event_role.role_arn
}

module "cw_event_role" {
  source = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"

  role_name        = var.cloudwatch_event_name
  trusted_services = ["events.amazonaws.com"]

  statements = [
    {
      sid    = "LambdaInvokeAccess"
      effect = "Allow"
      actions = [
        "lambda:InvokeFunction"
      ]
      resources = [module.lambda_trigger_sf.function_arn]
    }
  ]
}

resource "aws_sfn_state_machine" "this" {
  name     = var.step_function_name
  role_arn = module.sf_role.role_arn

  definition = jsonencode(
    {
      StartAt = "CreateTargets"
      States = {
        CreateTargets = {
          Type     = "Task"
          Resource = "arn:aws:states:::codebuild:startBuild.sync"
          Parameters = {
            ProjectName = module.codebuild_queue_pr.name
          }
          End = true
        }
      }
    }
  )
}

data "archive_file" "lambda_trigger_sf" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/lambda_function.zip"
}

module "lambda_trigger_sf" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_trigger_sf.output_path
  source_code_hash = data.archive_file.lambda_trigger_sf.output_base64sha256
  function_name    = var.lambda_trigger_sf_function_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  allowed_to_invoke = [
    {
      statement_id = "CloudWatchInvokeAccess"
      principal    = "events.amazonaws.com"
      arn          = aws_cloudwatch_event_rule.this.arn
    }
  ]
  env_vars = {
    GITHUB_TOKEN_SSM_KEY = var.github_token_ssm_key
    REPO_FULL_NAME       = data.github_repository.this.full_name
  }
  enable_cw_logs = true
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
  statements = [
    {
      sid       = "SimpledbQueryAccess"
      effect    = "Allow"
      actions   = ["sdb:Select"]
      resources = ["arn:aws:sdb:${data.aws_region.current.name}:${var.account_id}:domain/${var.simpledb_name}"]
    },
    {
      sid       = "StepFunctionTriggerAccess"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = [aws_sfn_state_machine.this.arn]
    }
  ]
}

module "sf_role" {
  source           = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name        = var.step_function_name
  trusted_services = ["states.amazonaws.com"]
  statements = [
    {
      sid       = "CodeBuildInvokeAccess"
      effect    = "Allow"
      actions   = ["codebuild:StartBuild"]
      resources = [module.codebuild_terraform.arn]
    }
  ]
}


module "codebuild_queue_pr" {
  source = "github.com/marshall7m/terraform-aws-codebuild"


  webhook_filter_groups = [
    [
      {
        pattern = "PULL_REQUEST_CREATED,PULL_REQUEST_UPDATED,PULL_REQUEST_REOPENED"
        type    = "EVENT"
      },
      {
        pattern = var.base_branch
        type    = "BASE_REF"
      },
      {
        pattern = var.file_path_pattern
        type    = "FILE_PATH"
      }
    ]
  ]
  source_auth_ssm_param_name = var.github_token_ssm_key
  source_auth_type           = "PERSONAL_ACCESS_TOKEN"
  source_auth_server_type    = "GITHUB"

  name = var.queue_pr_build_name
  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_queue.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = true
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:3.0"
    type         = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "DOMAIN_NAME"
        type  = "PLAINTEXT"
        value = var.simpledb_name
      }
    ]
  }

  role_policy_statements = [
    {
      sid    = "SimpleDBWriteAccess"
      effect = "Allow"
      actions = [
        "sdb:PutAttributes"
      ]
      resources = ["arn:aws:sdb:${data.aws_region.current.name}:${var.account_id}:domain/${var.simpledb_name}"]
    }
  ]
}

resource "aws_simpledb_domain" "queue" {
  name = var.simpledb_name
}