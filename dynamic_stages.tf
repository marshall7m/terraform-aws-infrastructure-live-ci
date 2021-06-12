locals {
  trigger_cp_build_name = "trigger-${var.pipeline_name}"
}

data "aws_region" "current" {}

# resource "aws_cloudwatch_event_rule" "pipeline" {
#   name        = var.cloudwatch_event_name
#   description = "Captures pipeline-level events for AWS CodePipeline: ${var.pipeline_name}"

#   event_pattern = jsonencode(
#     {
#       source      = ["aws.codepipeline"]
#       detail-type = ["CodePipeline Pipeline Execution State Change"]
#       detail = {
#         pipeline = [var.pipeline_name]
#         state    = ["SUCCEEDED"]
#       }
#     }
#   )
# }

# resource "aws_cloudwatch_event_target" "pipeline" {
#   rule      = aws_cloudwatch_event_rule.pipeline.name
#   target_id = "SendToSF"
#   arn       = aws_sfn_state_machine.this.arn
# }

resource "aws_sfn_state_machine" "this" {
  name     = var.step_function_name
  role_arn = module.sf_role.role_arn

  definition = jsonencode(
    {
      StartAt = "PollCP"
      States = {
        PollCP = {
          Type     = "Task"
          Resource = "arn:aws:states:::events:putEvents.waitForTaskToken"
          Parameters = {
            Entries = [
              {
                Source = "aws.codepipeline"
                DetailType  = "CodePipeline Pipeline Execution State Change"
                Detail = {
                  "TaskToken.$" =  "$$.Task.Token"
                  Pipeline = [var.pipeline_name]
                  State = ["SUCCEEDED"]
                }
              }
            ]
          }
          Next = "UpdateCP"
        },
        UpdateCP = {
          Type     = "Task"
          Resource = "arn:aws:states:::codebuild:startBuild.sync"
          Parameters = {
            ProjectName = local.trigger_cp_build_name
            "SourceVersion.$" = "$.source_version"
          }
          End = true
        }
      }
    }
  )
}

module "sf_role" {
  source           = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name        = var.step_function_name
  trusted_services = ["states.amazonaws.com"]
  statements = [
    {
      sid       = "LambdaInvokeAccess"
      effect    = "Allow"
      actions   = ["codebuild:StartBuild"]
      resources = [module.trigger_cp.arn]
    },
    {
      sid       = "EventBridgeAccess"
      effect    = "Allow"
      actions   = [
        "events:*"
      ]
      resources = ["*"]
    }
  ]
}

module "trigger_sf" {
  source = "github.com/marshall7m/terraform-aws-codebuild"

  name = "trigger-sf"
  webhook_filter_groups = var.webhook_filter_groups

  source_auth_token = var.github_token_ssm_value
  source_auth_server_type = "GITHUB"
  source_auth_type = "PERSONAL_ACCESS_TOKEN"
  source_auth_ssm_param_name = var.github_token_ssm_key

  build_source = {
    type = "GITHUB"
    buildspec       = "buildspec_trigger_sf.yaml"
    git_clone_depth = 1
    insecure_ssl        = false
    location            = data.github_repository.this.git_clone_url
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
        name  = "STATE_MACHINE_ARN"
        value = aws_sfn_state_machine.this.arn
        type  = "PLAINTEXT"
      }
    ]
  }
  
  role_policy_statements = [
    {
      sid       = "StepFunctionTriggerAccess"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = [aws_sfn_state_machine.this.arn]
    }
  ]
}

module "trigger_cp" {
  source = "github.com/marshall7m/terraform-aws-codebuild"

  name = local.trigger_cp_build_name
  build_source = {
    type = "GITHUB"
    buildspec       = "buildspec"
    git_clone_depth = 1
    insecure_ssl        = false
    location            = data.github_repository.this.git_clone_url
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
        name  = "STATE_MACHINE_ARN"
        value = "aws:states:${data.aws_region.current.name}:${var.account_id}:stateMachine:${var.step_function_name}"
        type  = "PLAINTEXT"
      }
    ]
  }

  role_policy_statements = [
    {
      sid       = "CodePipelineTriggerAccess"
      effect    = "Allow"
      actions   = ["codepipeline:StartPipelineExecution"]
      resources = [module.codepipeline.arn]
    }
  ]
}