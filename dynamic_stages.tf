locals {
  buildspec_scripts_key = "build-scripts"
  pr_queue_key          = "pr_queue.json"
}

resource "aws_sfn_state_machine" "this" {
  name     = var.step_function_name
  role_arn = module.sf_role.role_arn
  definition = jsonencode({
    StartAt = "Plan"
    States = {
      "Plan" = {
        Next = "Request Approval"
        Parameters = {
          SourceVersion = "$.HeadSourceVersion"
          EnvironmentVariablesOverride = [
            {
              Name      = "TARGET_PATH"
              Type      = "PLAINTEXT"
              "Value.$" = "$.DeploymentPath"
            },
            {
              Name  = "PLAN_COMMAND"
              Type  = "PLAINTEXT"
              Value = "$.PlanCommand"
            }
          ]
          ProjectName = var.build_name
        }
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Type     = "Task"
      },
      "Request Approval" = {
        Next = "Approval Results"
        Parameters = {
          FunctionName = module.lambda_approval_request.function_arn
          Payload = {
            StateMachine = "$$.StateMachine.Id"
            ExecutionId  = "$$.Execution.Name"
            TaskToken    = "$$.Task.Token"
            Account      = "$.Account"
            Path         = "$.DeploymentPath"
          }
        }
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Type     = "Task"
      },
      "Approval Results" = {
        Choices = [
          {
            Next         = "Apply"
            StringEquals = "Approve"
            Variable     = "$.Status"
          },
          {
            Next         = "Reject"
            StringEquals = "Reject"
            Variable     = "$.Status"
          }
        ]
        Type = "Choice"
      },
      "Apply" = {
        End = true
        Parameters = {
          SourceVersion = "$.HeadSourceVersion"
          EnvironmentVariablesOverride = [
            {
              Name      = "TARGET_PATH"
              Type      = "PLAINTEXT"
              "Value.$" = "$.DeploymentPath"
            },
            {
              Name  = "APPLY_COMMAND"
              Type  = "PLAINTEXT"
              Value = "$.ApplyCommand"
            }
          ]
          ProjectName = var.build_name
        }
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Type     = "Task"
      },
      "Reject" = {
        Cause = "Terraform plan was rejected"
        Error = "RejectedPlan"
        Type  = "Fail"
      }
    }
  })
}

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

module "cw_target_role" {
  source           = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name        = "CodeBuildTriggerStepFunction"
  trusted_services = ["events.amazonaws.com"]
  statements = [
    {
      sid       = "CodeBuildInvokeAccess"
      effect    = "Allow"
      actions   = ["codebuild:StartBuild"]
      resources = [module.codebuild_trigger_sf.arn]
    }
  ]
}

resource "aws_cloudwatch_event_target" "sf" {
  rule      = aws_cloudwatch_event_rule.this.name
  target_id = "CodeBuildTriggerStepFunction"
  arn       = module.codebuild_trigger_sf.arn
  role_arn  = module.cw_target_role.role_arn
}

resource "aws_sfn_activity" "manual_approval" {
  name = "manual-approval"
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

module "codebuild_trigger_sf" {
  source = "github.com/marshall7m/terraform-aws-codebuild"

  name = var.trigger_step_function_build_name

  source_auth_token          = var.github_token_ssm_value
  source_auth_server_type    = "GITHUB"
  source_auth_type           = "PERSONAL_ACCESS_TOKEN"
  source_auth_ssm_param_name = var.github_token_ssm_key

  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_trigger_sf.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }

  environment = {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = coalesce(var.terra_img, module.terra_img[0].full_image_url)
    image_pull_credentials_type = "SERVICE_ROLE"
    type                        = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "BUILD_NAME"
        value = var.trigger_step_function_build_name
        type  = "PLAINTEXT"
      },
      {
        name  = "STATE_MACHINE_ARN"
        value = aws_sfn_state_machine.this.arn
        type  = "PLAINTEXT"
      },
      {
        name  = "TERRAGRUNT_WORKING_DIR"
        type  = "PLAINTEXT"
        value = var.terragrunt_parent_dir
      },
      {
        name  = "ARTIFACT_BUCKET_NAME"
        type  = "PLAINTEXT"
        value = aws_s3_bucket.artifacts.id
      },
      {
        name  = "APPROVAL_MAPPING_S3_KEY"
        type  = "PLAINTEXT"
        value = local.approval_mapping_s3_key
      },
      {
        name  = "SECONDARY_SOURCE_IDENTIFIER"
        type  = "PLAINTEXT"
        value = local.buildspec_scripts_key
      },
      {
        name  = "EVENTBRIDGE_RULE"
        type  = "PLAINTEXT"
        value = aws_cloudwatch_event_rule.id
      }
    ]
  }
  role_policy_arns = [aws_iam_policy.artifact_bucket_access.arn]

  role_policy_statements = [
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
      sid     = "CodeBuildInvokeAccess"
      effect  = "Allow"
      actions = ["codebuild:StartBuild"]
      resources = [
        module.codebuild_terraform_deploy.arn,
        module.codebuild_rollback_provider.arn
      ]
    },
    {
      sid     = "LambdaInvokeAccess"
      effect  = "Allow"
      actions = ["lambda:Invoke"]
      resources = [
        module.lambda_approval_request.function_arn,
        module.lambda_deployment_orchestrator.function_arn
      ]
    },
    {
      sid    = "CloudWatchEventsAccess"
      effect = "Allow"
      actions = [
        "events:PutTargets",
        "events:PutRule",
        "events:DescribeRule"
      ]
      resources = ["*"]
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

  create_source_auth         = true
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
        name  = "ARTIFACT_BUCKET_NAME"
        type  = "PLAINTEXT"
        value = aws_s3_bucket.artifacts.id
      },
      {
        name  = "ARTIFACT_BUCKET_PR_QUEUE_KEY"
        type  = "PLAINTEXT"
        value = local.pr_queue_key
      }
    ]
  }

  role_policy_arns = [aws_iam_policy.artifact_bucket_access.arn]
}

module "terra_img" {
  count  = var.terra_img == null ? 1 : 0
  source = "github.com/marshall7m/terraform-aws-ecr/modules//ecr-docker-img"

  create_repo         = true
  codebuild_access    = true
  source_path         = "${path.module}/modules/testing-img"
  repo_name           = "infrastructure-live-ci"
  tag                 = "latest"
  trigger_build_paths = ["${path.module}/modules/testing-img"]
}

data "archive_file" "lambda_deployment_orchestrator" {
  type        = "zip"
  source_dir  = "${path.module}/functions/deployment_orchestrator"
  output_path = "${path.module}/deployment_orchestrator.zip"
}

module "lambda_deployment_orchestrator" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_deployment_orchestrator.output_path
  source_code_hash = data.archive_file.lambda_deployment_orchestrator.output_base64sha256
  function_name    = "${var.step_function_name}-deployment-orchestrator"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"

  env_vars = {
    ARTIFACT_BUCKET_NAME = aws_s3_bucket.artifacts.id
  }

  custom_role_policy_arns = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
}


resource "aws_cloudwatch_event_rule" "sf_execution" {
  name        = "${var.step_function_name}-execution"
  description = "Triggers Codebuild project when Step Function execution is complete"
  role_arn    = module.cw_event_role.role_arn

  event_pattern = <<EOF
{
  "source": ["aws.states"],
  "detail-type": ["Step Functions Execution Status Change"],
  "detail": {
    "status": ["RUNNING", "FAILED"],
    "stateMachineArn": [${aws_sfn_state_machine.this.arn}]
  }
}
EOF
}

resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.sf_execution.name
  target_id = "SendToCodebuildTriggerSF"
  arn       = module.codebuild_trigger_sf.arn
}


module "cw_event_role" {
  source = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"

  role_name        = "agw-logs"
  trusted_services = ["events.amazonaws.com"]
  statements = [
    {
      effect = "Allow"
      actions = [
        "codebuild:StartBuild"
      ]
      resources = [module.codebuild_trigger_sf.arn]
    }
  ]
}

