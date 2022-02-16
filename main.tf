locals {
  cloudwatch_event_rule_name = coalesce(var.cloudwatch_event_rule_name, "${var.step_function_name}-finished-execution")
  state_machine_arn          = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:stateMachine:${var.step_function_name}"
  cw_event_terra_run_rule    = "${local.terra_run_build_name}-rule"
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
          EnvironmentVariablesOverride = [
            {
              Name      = "ROLE_ARN"
              Type      = "PLAINTEXT"
              "Value.$" = "$.plan_role_arn"
            },
            {
              Name      = "TG_COMMAND"
              Type      = "PLAINTEXT"
              "Value.$" = "$.plan_command"
            }
          ]
          ProjectName = module.codebuild_terra_run.name
        }
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Type     = "Task"
      },
      "Request Approval" = {
        Next = "Approval Results"
        Parameters = {
          FunctionName = module.lambda_approval_request.function_arn
          Payload = {
            PathApproval = {
              "Approval" = {
                Required = "$.min_approval_count"
                Count    = 0
                Voters   = []
              },
              "Rejection" = {
                "Required" = "$.min_rejection_count"
                "Count"    = 0
                "Voters"   = []
              },
              "AwaitingApprovals" = "$.voters"
              "TaskToken"         = "$$.Task.Token"
            }
            Voters        = "$.voters"
            ApprovalAPI   = "States.Format('${aws_api_gateway_deployment.approval.invoke_url}${aws_api_gateway_stage.approval.stage_name}${aws_api_gateway_resource.approval.path}?ex={}&sm={}&taskToken={}, $$.Execution.Name, $$.StateMachine.Id, $$.Task.Token)"
            ExecutionName = "$$.Execution.Name"
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
            Variable     = "$.status"
          },
          {
            Next         = "Reject"
            StringEquals = "Reject"
            Variable     = "$.status"
          }
        ]
        Type = "Choice"
      },
      "Apply" = {
        End = true
        Parameters = {
          EnvironmentVariablesOverride = [
            {
              Name      = "ROLE_ARN"
              Type      = "PLAINTEXT"
              "Value.$" = "$.deploy_role_arn"
            },
            {
              Name      = "TG_COMMAND"
              Type      = "PLAINTEXT"
              "Value.$" = "$.deploy_command"
            }
          ]
          ProjectName = module.codebuild_terra_run.name
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

module "sf_role" {
  source           = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name        = var.step_function_name
  trusted_services = ["states.amazonaws.com"]
  statements = [
    {
      sid    = "CodeBuildInvokeAccess"
      effect = "Allow"
      actions = [
        "codebuild:StartBuild",
        "codebuild:StopBuild",
        "codebuild:BatchGetBuilds"
      ]
      resources = [
        module.codebuild_terra_run.arn
      ]
    },
    {
      sid     = "LambdaInvokeAccess"
      effect  = "Allow"
      actions = ["lambda:InvokeFunction"]
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
      resources = [
        "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:rule/StepFunctionsGetEventForCodeBuildStartBuildRule"
      ]
    }
  ]
}

resource "aws_cloudwatch_event_target" "sf_execution" {
  rule      = aws_cloudwatch_event_rule.sf_execution.name
  target_id = "CodeBuildTriggerStepFunction"
  arn       = module.codebuild_trigger_sf.arn
  role_arn  = module.cw_event_rule_role.role_arn
}

resource "aws_cloudwatch_event_rule" "sf_execution" {
  name        = local.cloudwatch_event_rule_name
  description = "Triggers Codebuild project when Step Function execution is complete"
  role_arn    = module.cw_event_rule_role.role_arn

  event_pattern = jsonencode({
    source      = ["aws.states"]
    detail-type = ["Step Functions Execution Status Change"],
    detail = {
      status          = ["SUCCESS", "FAILED"],
      stateMachineArn = [local.state_machine_arn]
    }
  })
}

module "cw_event_rule_role" {
  source = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"

  role_name        = local.cloudwatch_event_rule_name
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

resource "aws_cloudwatch_event_target" "codebuild_terra_run" {
  rule      = aws_cloudwatch_event_rule.codebuild_terra_run.name
  target_id = "StepFunctionsGetEventForCodeBuildStartBuildRule"
  arn       = local.state_machine_arn
  role_arn  = module.cw_event_terra_run.role_arn
}

resource "aws_cloudwatch_event_rule" "codebuild_terra_run" {
  name        = local.cw_event_terra_run_rule
  description = "This rule is used to notify Step Function regarding AWS CodeBuild build"

  event_pattern = jsonencode({
    source      = ["aws.codebuild"]
    detail-type = ["CodeBuild Build State Change"]
    detail = {
      build-status = [
        "SUCCEEDED",
        "FAILED",
        "FAULT",
        "TIMED_OUT",
        "STOPPED"
      ],
      additional-information = {
        initiator = [{
          prefix = "states/"
        }]
      }
    }
  })
}

module "cw_event_terra_run" {
  source = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"

  role_name        = local.cw_event_terra_run_rule
  trusted_services = ["events.amazonaws.com"]
  statements = [
    {
      effect = "Allow"
      actions = [
        "states:SendTaskSuccess",
        "states:SendTaskFailure",
        "states:SendTaskHeartbeat",
        "states:GetActivityTask"
      ]
      resources = [local.state_machine_arn]
    }
  ]
}
