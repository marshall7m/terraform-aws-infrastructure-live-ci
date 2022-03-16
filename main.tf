locals {
  cloudwatch_event_rule_name = coalesce(var.cloudwatch_event_rule_name, "${var.step_function_name}-finished-execution")
  state_machine_arn          = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:stateMachine:${var.step_function_name}"
  cw_event_terra_run_rule    = "${local.terra_run_build_name}-rule"
  approval_url               = "${module.github_webhook_validator.deployment_invoke_url}${module.github_webhook_validator.api_stage_name}${aws_api_gateway_resource.approval.path}"
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
        Resource   = "arn:aws:states:::codebuild:startBuild.sync"
        Type       = "Task"
        ResultPath = null
        # TODO: Create terraform specific error catching/retries 
        # (e.g. tf plan timeout results in task to retry or tf deploy role arn has insufficient permissions results in waiting till user updates deploy role permissions)
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "Reject"
            ResultPath  = null
          }
        ]
      },
      "Request Approval" = {
        Next = "Approval Results"
        Parameters = {
          FunctionName = module.lambda_approval_request.function_arn
          Payload = {
            "PathApproval" = {
              "Approval" = {
                "Required.$" = "$.min_approval_count"
                Count        = 0
                Voters       = []
              },
              "Rejection" = {
                "Required.$" = "$.min_rejection_count"
                "Count"      = 0
                "Voters"     = []
              },
              "AwaitingApprovals.$" = "$.voters"
              "TaskToken.$"         = "$$.Task.Token"
            }
            "Voters.$"        = "$.voters"
            "Path.$"          = "$.cfg_path"
            "ApprovalAPI.$"   = "States.Format('${local.approval_url}?ex={}&sm={}&taskToken={}', $$.Execution.Name, $$.StateMachine.Id, $$.Task.Token)"
            "ExecutionName.$" = "$$.Execution.Name"
          }
        }
        Resource   = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Type       = "Task"
        ResultPath = "$.Action"
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "Reject"
            ResultPath  = null
          }
        ]
      },
      "Approval Results" = {
        Choices = [
          {
            Next         = "Deploy"
            StringEquals = "approve"
            Variable     = "$.Action"
          },
          {
            Next         = "Reject"
            StringEquals = "reject"
            Variable     = "$.Action"
          }
        ]
        Type = "Choice"
      },
      "Deploy" = {
        Next = "Success"
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
        Resource   = "arn:aws:states:::codebuild:startBuild.sync"
        Type       = "Task"
        ResultPath = null
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "Reject"
            ResultPath  = null
          }
        ]
      },
      "Success" = {
        Type = "Pass"
        Parameters = {
          "execution_id.$"  = "$.execution_id"
          "is_rollback.$"   = "$.is_rollback"
          "new_providers.$" = "$.new_providers"
          "plan_role_arn.$" = "$.plan_role_arn"
          "cfg_path.$"      = "$.cfg_path"
          "commit_id.$"     = "$.commit_id"
          "status"          = "succeeded"
        }
        End = true
      },
      "Reject" = {
        Type = "Pass"
        Parameters = {
          "execution_id.$"  = "$.execution_id"
          "is_rollback.$"   = "$.is_rollback"
          "new_providers.$" = "$.new_providers"
          "plan_role_arn.$" = "$.plan_role_arn"
          "cfg_path.$"      = "$.cfg_path"
          "commit_id.$"     = "$.commit_id"
          "status"          = "failed"
        }
        End = true
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
  input_transformer {
    input_paths = {
      output = "$.detail.output"
    }
    input_template = <<EOF
{
  "environmentVariablesOverride": [
    {
      "name": "EXECUTION_OUTPUT",
      "type": "PLAINTEXT",
      "value": <output>
    }
  ]
}
EOF
  }
}

resource "aws_cloudwatch_event_rule" "sf_execution" {
  name        = local.cloudwatch_event_rule_name
  description = "Triggers Codebuild project when Step Function execution is complete"
  role_arn    = module.cw_event_rule_role.role_arn

  event_pattern = jsonencode({
    source      = ["aws.states"]
    detail-type = ["Step Functions Execution Status Change"],
    detail = {
      status          = ["SUCCEEDED", "FAILED", "ABORTED"],
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
