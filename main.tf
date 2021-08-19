locals {
  buildspec_scripts_source_identifier = "helpers"
  buildspec_scripts_key               = "build-scripts"
  pr_queue_key                        = "pr_queue.json"
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
              Name    = "DEPLOYMENT_STAGE"
              Type    = "PLAINTEXT"
              "Value" = "Plan"
            },
            {
              Name      = "DEPLOYMENT_TYPE"
              Type      = "PLAINTEXT"
              "Value.$" = "$.DeploymentType"
            },
            {
              Name      = "TARGET_PATH"
              Type      = "PLAINTEXT"
              "Value.$" = "$.DeploymentPath"
            },
            {
              Name      = "PLAN_COMMAND"
              Type      = "PLAINTEXT"
              "Value.$" = "$.PlanCommand"
            }
          ]
          ProjectName = module.codebuild_terragrunt_deploy.name
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
              Name    = "DEPLOYMENT_STAGE"
              Type    = "PLAINTEXT"
              "Value" = "Deploy"
            },
            {
              Name      = "DEPLOYMENT_TYPE"
              Type      = "PLAINTEXT"
              "Value.$" = "$.DeploymentType"
            },
            {
              Name      = "TARGET_PATH"
              Type      = "PLAINTEXT"
              "Value.$" = "$.DeploymentPath"
            },
            {
              Name      = "DEPLOY_COMMAND"
              Type      = "PLAINTEXT"
              "Value.$" = "$.DeployCommand"
            }
          ]
          ProjectName = module.codebuild_terragrunt_deploy.name
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
        module.codebuild_terragrunt_deploy.arn
      ]
    },
    {
      sid     = "LambdaInvokeAccess"
      effect  = "Allow"
      actions = ["lambda:Invoke"]
      resources = [
        module.lambda_approval_request.function_arn
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


resource "aws_cloudwatch_event_rule" "sf_execution" {
  name        = "${var.step_function_name}-finished-execution"
  description = "Triggers Codebuild project when Step Function execution is complete"
  role_arn    = module.cw_event_role.role_arn

  event_pattern = jsonencode({
    source      = ["aws.states"]
    detail-type = ["Step Functions Execution Status Change"],
    detail = {
      status          = ["SUCCESS", "FAILED"],
      stateMachineArn = [aws_sfn_state_machine.this.arn]
    }
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.sf_execution.name
  target_id = "SendToCodebuildTriggerSF"
  role_arn  = module.cw_event_role.role_arn
  arn       = module.codebuild_trigger_sf.arn
}

module "cw_event_role" {
  source = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"

  role_name        = "${var.step_function_name}-finished-execution"
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