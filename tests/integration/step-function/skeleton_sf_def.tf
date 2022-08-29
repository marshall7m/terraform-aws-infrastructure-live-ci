locals {
  definition = {
    StartAt = "Plan"
    States = {
      "Plan" = {
        Next = "Request Approval"
        Parameters = {
          Cluster        = aws_ecs_cluster.this.arn
          TaskDefinition = aws_ecs_task_definition.terra_run.arn
          LaunchType     = "FARGATE"
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = ["subnet-123"]
              SecurityGroups = ["sg-123"]
              AssignPublicIp = local.ecs_assign_public_ip
            }
          }
          Overrides = {
            TaskRoleArn = module.plan_role.role_arn
            ContainerOverrides = [
              {
                Name = local.terra_run_container_name
                Environment = [
                  {
                    "Name"    = "TG_COMMAND"
                    "Value.$" = "$.plan_command"
                  },
                  {
                    "Name"    = "TASK_TOKEN"
                    "Value.$" = "$$.Task.Token"
                  },
                ]
              }
            ]
          }
        }
        Resource   = "arn:aws:states:::ecs:runTask.sync"
        Type       = "Task"
        ResultPath = "$.PlanOutput"
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
            "PlanOutput"        = "$.PlanOutput"
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
            AwsvpcConfiguration = {
              Subnets        = ["subnet-123"]
              SecurityGroups = ["sg-123"]
              AssignPublicIp = local.ecs_assign_public_ip
            }
          }
          Overrides = {
            TaskRoleArn = module.apply_role.role_arn
            ContainerOverrides = [
              {
                Name = local.terra_run_container_name
                Environment = [
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
}