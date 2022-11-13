locals {
  step_function_name         = "${var.prefix}-${var.step_function_name}"
  cloudwatch_event_rule_name = "${local.step_function_name}-finished-execution"
  state_machine_arn          = "arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:stateMachine:${local.step_function_name}"
  cw_event_terra_run_rule    = "${local.terra_run_family}-rule"

  log_url_prefix    = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#logsV2:log-groups/log-group/${aws_cloudwatch_log_group.ecs_tasks.name}/log-events/"
  log_stream_prefix = "${local.terra_run_logs_prefix}/${local.terra_run_container_name}/"
  common_terra_run_env_vars = concat([for v in concat(local.ecs_tasks_base_env_vars, var.ecs_tasks_common_env_vars) : { "Name" : "${v.name}", "Value" : "${v.value}" }], [
    {
      "Name"    = "STATE_NAME"
      "Value.$" = "$$.State.Name"
    },
    {
      "Name"    = "STATUS_CHECK_NAME"
      "Value.$" = "States.Format('{} {}: {}', $$.Execution.Name, $$.State.Name, $.cfg_path)"
    },
    {
      "Name"    = "COMMIT_ID"
      "Value.$" = "$.commit_id"
    },
  ])
  repo_full_name        = trimsuffix(trim(regex("(?:(?P<scheme>[^:/?#]+):)?(?://(?P<authority>[^/?#]*))?(?P<path>[^?#]*)(?:\\?(?P<query>[^#]*))?(?:#(?P<fragment>.*))?", var.repo_clone_url).path, "/"), ".git")
  sf_ecs_network_config = { for key, value in local.ecs_network_config : title(key) => value }
}

resource "aws_sfn_state_machine" "this" {
  name     = local.step_function_name
  role_arn = module.sf_role.role_arn
  definition = jsonencode(
    {
      StartAt = "Plan"
      States = {
        "Plan" = {
          Next = "Request Approval"
          Parameters = {
            Cluster        = aws_ecs_cluster.this.arn
            TaskDefinition = aws_ecs_task_definition.terra_run.arn
            LaunchType     = "FARGATE"
            NetworkConfiguration = {
              AwsvpcConfiguration = local.sf_ecs_network_config
            }
            Overrides = {
              TaskRoleArn = module.terra_run_plan_role.role_arn
              ContainerOverrides = [
                {
                  Name = local.terra_run_container_name
                  Environment = concat(
                    local.common_terra_run_env_vars, [
                      {
                        "Name"    = "TG_COMMAND"
                        "Value.$" = "$.plan_command"
                      },
                      {
                        "Name"    = "TASK_TOKEN"
                        "Value.$" = "$$.Task.Token"
                      },
                    ]
                  )
                }
              ]
            }
          }
          Resource   = "arn:aws:states:::ecs:runTask.waitForTaskToken"
          Type       = "Task"
          ResultPath = "$.LogsUrl"
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
            TopicArn = aws_sns_topic.approval.arn
            Message = {
              "Voters.$"          = "$.voters"
              "Path.$"            = "$.cfg_path"
              "ApprovalURL"       = module.lambda_approval_response.lambda_function_url
              "ExecutionArn.$"    = "$$.Execution.Id"
              "StateMachineArn.$" = "$$.StateMachine.Id"
              "TaskToken.$"       = "$$.Task.Token"
              "ExecutionName.$"   = "$$.Execution.Name"
              "AccountName.$"     = "$.account_name"
              "PullRequestID.$"   = "$.pr_id"
              "LogsUrl"           = "$.LogsUrl"
            }
          }
          Resource   = "arn:aws:states:::sns:publish.waitForTaskToken"
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
              Next         = "Apply"
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
        "Apply" = {
          Next = "Success"
          Parameters = {
            Cluster        = aws_ecs_cluster.this.arn
            TaskDefinition = aws_ecs_task_definition.terra_run.arn
            LaunchType     = "FARGATE"
            NetworkConfiguration = {
              AwsvpcConfiguration = local.sf_ecs_network_config
            }
            Overrides = {
              TaskRoleArn = module.terra_run_apply_role.role_arn
              ContainerOverrides = [
                {
                  Name = local.terra_run_container_name
                  Environment = concat(
                    local.common_terra_run_env_vars, [
                      {
                        "Name"    = "TG_COMMAND"
                        "Value.$" = "$.apply_command"
                      },
                      {
                        "Name"    = "EXECUTION_ID"
                        "Value.$" = "$.execution_id"
                      },
                      {
                        "Name"    = "ROLE_ARN"
                        "Value.$" = "$.apply_role_arn"
                      },
                      {
                        "Name"    = "CFG_PATH"
                        "Value.$" = "$.cfg_path"
                      },
                      {
                        "Name"    = "NEW_PROVIDERS"
                        "Value.$" = "States.JsonToString($.new_providers)"
                      },
                      {
                        "Name"    = "IS_ROLLBACK"
                        "Value.$" = "States.JsonToString($.is_rollback)"
                      },
                      {
                        "Name"  = "METADB_NAME"
                        "Value" = local.metadb_name
                      },
                      {
                        "Name"  = "AURORA_CLUSTER_ARN"
                        "Value" = aws_rds_cluster.metadb.arn
                      },
                      {
                        "Name"  = "AURORA_SECRET_ARN"
                        "Value" = aws_secretsmanager_secret_version.ci_metadb_user.arn
                      },
                      {
                        "Name"    = "TASK_TOKEN"
                        "Value.$" = "$$.Task.Token"
                      },
                    ]
                  )
                }
              ]
            }
          }
          Resource   = "arn:aws:states:::ecs:runTask.sync"
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
    }
  )
}

module "sf_role" {
  source           = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"
  role_name        = local.step_function_name
  trusted_services = ["states.amazonaws.com"]
  statements = [
    {
      sid    = "ECSRunAccess"
      effect = "Allow"
      actions = [
        "ecs:RunTask"
      ]
      conditions = [
        {
          test     = "ArnEquals"
          variable = "ecs:cluster"
          values   = [aws_ecs_cluster.this.arn]
        }
      ]
      resources = [
        aws_ecs_task_definition.terra_run.arn,
      ]
    },
    {
      effect = "Allow"
      actions = [
        "iam:PassRole"
      ]
      resources = [
        module.ecs_execution_role.role_arn,
        module.terra_run_plan_role.role_arn,
        module.terra_run_apply_role.role_arn
      ]
    },
    {
      effect = "Allow"
      actions = [
        "ecs:StopTask",
        "ecs:DescribeTasks"
      ]
      resources = ["*"]
    },
    {
      sid     = "LambdaInvokeAccess"
      effect  = "Allow"
      actions = ["lambda:InvokeFunction"]
      resources = [
        module.lambda_approval_request.lambda_function_arn
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
        "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:rule/StepFunctionsGetEventsForECSTaskRule"
      ]
    },
    {
      sid       = "SNSPublishAccess"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.approval.arn]
    }
  ]
}

resource "aws_cloudwatch_event_target" "sf_execution" {
  rule      = aws_cloudwatch_event_rule.sf_execution.name
  target_id = "LambdaTriggerStepFunction"
  arn       = module.lambda_trigger_sf.lambda_function_arn
  input_transformer {
    input_paths = {
      output = "$.detail.output",
      input  = "$.detail.input",
      status = "$.detail.status"
    }
    input_template = <<EOF
{
  "execution": {
    "output": <output>,
    "input": <input>,
    "status": <status>
  }
}
EOF
  }
}

resource "aws_cloudwatch_event_rule" "sf_execution" {
  name        = local.cloudwatch_event_rule_name
  description = "Triggers Lambda function: ${local.trigger_sf_function_name} when Step Function execution is complete"
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
  source = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"

  role_name        = local.cloudwatch_event_rule_name
  trusted_services = ["events.amazonaws.com"]
  statements = [
    {
      effect = "Allow"
      actions = [
        "lambda:GetFunction",
        "lambda:InvokeFunction"
      ]
      resources = [module.lambda_trigger_sf.lambda_function_arn]
    }
  ]
}

resource "aws_cloudwatch_event_target" "terra_run" {
  rule      = aws_cloudwatch_event_rule.ecs_terra_run.name
  target_id = "StepFunctionsGetEventsForECSTaskRule"
  arn       = local.state_machine_arn
  role_arn  = module.cw_event_terra_run.role_arn
}

resource "aws_cloudwatch_event_rule" "ecs_terra_run" {
  name        = local.cw_event_terra_run_rule
  description = "This rule is used to notify Step Function regarding AWS ECS tasks"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this.arn],
      additional-information = {
        initiator = [{
          prefix = "states/"
        }]
      }
    }
  })
}

module "cw_event_terra_run" {
  source = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"

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
