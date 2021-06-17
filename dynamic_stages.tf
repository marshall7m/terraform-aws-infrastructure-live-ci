data "aws_region" "current" {}

resource "aws_cloudwatch_event_rule" "this" {
  name        = var.cloudwatch_event_name
  description = "Captures execution-level events for AWS Step Function: ${var.step_function_name}"

  event_pattern = jsonencode(
    {
      source      = ["aws.states"]
      detail-type = ["Step Functions Execution Status Change"]
      detail = {
        stateMachineArn = [aws_sfn_state_machine.this.arn]
        state           = ["SUCCEEDED"]
      }
    }
  )
}

resource "aws_cloudwatch_event_target" "sf" {
  rule      = aws_cloudwatch_event_rule.this.name
  target_id = "LambdaTriggerSF"
  arn       = module.lambda_trigger_sf.function_arn
}

resource "aws_sfn_state_machine" "this" {
  name     = var.step_function_name
  role_arn = module.sf_role.role_arn

  definition = jsonencode(
    {
      StartAt = "CreateTargets"
      States = {
        CreateTargets = {
          Type = "Pass"
          End  = true
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

data "archive_file" "lambda_deps" {
  type        = "zip"
  source_dir  = "${path.module}/deps"
  output_path = "${path.module}/lambda_deps.zip"
  depends_on = [
    null_resource.lambda_pip_deps
  ]
}

# pip install runtime packages needed for function
resource "null_resource" "lambda_pip_deps" {
  triggers = {
    zip_hash = fileexists("${path.module}/lambda_deps.zip") ? 0 : timestamp()
  }
  provisioner "local-exec" {
    command = <<EOF
    pip install --target ${path.module}/deps/python PyGithub==1.54.1
    EOF
  }
}

resource "aws_ssm_parameter" "github_token" {
  count       = var.create_github_token_ssm_param && var.github_token_ssm_value != "" ? 1 : 0
  name        = var.github_token_ssm_key
  description = var.github_token_ssm_description
  type        = "SecureString"
  value       = var.github_token_ssm_value
  tags        = var.github_token_ssm_tags
}

data "aws_ssm_parameter" "github_token" {
  count = var.create_github_token_ssm_param == false && var.github_token_ssm_value == "" ? 1 : 0
  name  = var.github_token_ssm_key
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
    DOMAIN_NAME          = aws_simpledb_domain.queue.id
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
      sid       = "GithubTokenSSMParamAccess"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = [try(data.aws_ssm_parameter.github_token[0].arn, aws_ssm_parameter.github_token[0].arn)]
    },
    {
      sid       = "StepFunctionTriggerAccess"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = [aws_sfn_state_machine.this.arn]
    }
  ]
  lambda_layers = [
    {
      filename         = data.archive_file.lambda_deps.output_path
      name             = "${var.lambda_trigger_sf_function_name}-deps"
      runtimes         = ["python3.8"]
      source_code_hash = data.archive_file.lambda_deps.output_base64sha256
      description      = "Dependencies for lambda function: ${var.lambda_trigger_sf_function_name}"
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