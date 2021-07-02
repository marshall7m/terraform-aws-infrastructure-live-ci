locals {
  approval_msg = <<EOF
States.Format('
  This is an email requiring an approval for a step functions execution
  Check the following information and click "Approve" link if you want to approve

  Step Function State Machine: {}
  Execution ID: {}

  Approve:
  ${aws_api_gateway_deployment.approval.invoke_url}${aws_api_gateway_resource.approval.path}?action=approve&ex={}&sm={}&taskToken={}

  Reject:
  ${aws_api_gateway_deployment.approval.invoke_url}${aws_api_gateway_resource.approval.path}?action=reject&ex={}&sm={}&taskToken={}
  ',
  $$.StateMachine.Id,
  $$.Execution.Id,
  $$.Execution.Id,
  $$.StateMachine.Id,
  $$.Task.Token,
  $$.Execution.Id,
  $$.StateMachine.Id,
  $$.Task.Token)
  EOF
}

resource "aws_sfn_state_machine" "this" {
  name     = var.step_function_name
  role_arn = module.sf_role.role_arn
  definition = jsonencode({
    StartAt = var.account_parent_paths[0]
    States = merge({ for i in range(length(var.account_parent_paths)) : var.account_parent_paths[i] => {
      Type                                                       = "Map"
      "${can(var.account_parent_paths[i + 1]) ? "Next" : "End"}" = "${try(var.account_parent_paths[i + 1], true)}"
      Catch = [
        {
          ErrorEquals = [
            "States.TaskFailed",
            "RejectedPlan",
          ]
          Next = "Rollback Stack"
        },
      ]
      ItemsPath = "$.${var.account_parent_paths[i]}.RunOrder"
      Iterator = {
        StartAt = "Deploy"
        States = {
          Deploy = {
            Type           = "Map"
            MaxConcurrency = 1
            Parameters = {
              "Path.$" = "$$.Map.Item.Value"
            }
            End = true
            Iterator = {
              StartAt = "Plan"
              States = {
                "Plan" = {
                  Next = "Request Approval"
                  Parameters = {
                    EnvironmentVariablesOverride = [
                      {
                        Name      = "PATH"
                        Type      = "PLAINTEXT"
                        "Value.$" = "$.Path"
                      },
                      {
                        Name  = "COMMAND"
                        Type  = "PLAINTEXT"
                        Value = "plan"
                      },
                    ]
                    ProjectName = var.build_name
                  }
                  Resource = "arn:aws:states:::codebuild:startBuild.sync"
                  Type     = "Task"
                },
                "Request Approval" = {
                  Next = "Approval Results"
                  Parameters = {
                    TopicArn    = aws_sns_topic.approval.arn
                    Subject     = "Infrastructure-Live Approval Request"
                    "Message.$" = local.approval_msg
                  }
                  Resource = "arn:aws:states:::sns:publish.waitForTaskToken"
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
                Apply = {
                  End = true
                  Parameters = {
                    EnvironmentVariablesOverride = [
                      {
                        Name      = "PATH"
                        Type      = "PLAINTEXT"
                        "Value.$" = "$.Path"
                      },
                      {
                        Name  = "COMMAND"
                        Type  = "PLAINTEXT"
                        Value = "apply"
                      },
                      {
                        Name  = "EXTRA_ARGS"
                        Type  = "PLAINTEXT"
                        Value = "-auto-approve"
                      }
                    ]
                    ProjectName = var.build_name
                  }
                  Resource = "arn:aws:states:::codebuild:startBuild.sync"
                  Type     = "Task"
                },
                Reject = {
                  Cause = "Terraform plan was rejected"
                  Error = "RejectedPlan"
                  Type  = "Fail"
                }
              }
            }
          }
        }
      }
      } },
      {
        "Rollback Stack" = {
          Type = "Map"
          End  = true
          Iterator = {
            StartAt = "Deploy Rollback"
            States = {
              "Deploy Rollback" = {
                Type = "Map"
                Parameters = {
                  "Path.$" = "$$.Map.Item.Value"
                }
                End = true
                Iterator = {
                  StartAt = "Get Rollback Providers"
                  States = {
                    "Get Rollback Providers" = {
                      Type     = "Task"
                      Resource = "arn:aws:states:::codebuild:startBuild.sync"
                      Parameters = {
                        EnvironmentVariablesOverride = [
                          {
                            Name      = "PATH"
                            Type      = "PLAINTEXT"
                            "Value.$" = "$.Path"
                          }
                        ]
                        ProjectName = var.get_rollback_providers_build_name
                      }
                      Next = "Plan Rollback"
                    },
                    "Plan Rollback" = {
                      Next = "Request Rollback Approval"
                      Parameters = {
                        EnvironmentVariablesOverride = [
                          {
                            Name      = "PATH"
                            Type      = "PLAINTEXT"
                            "Value.$" = "$.Path"
                          },
                          {
                            Name  = "COMMAND"
                            Type  = "PLAINTEXT"
                            Value = "plan"
                          },
                        ]
                        ProjectName = var.build_name
                      }
                      Resource = "arn:aws:states:::codebuild:startBuild.sync"
                      Type     = "Task"
                    },
                    "Request Rollback Approval" = {
                      Next = "Rollback Approval Results"
                      Parameters = {
                        TopicArn    = aws_sns_topic.approval.arn
                        "Message.$" = local.approval_msg
                      }
                      Resource = "arn:aws:states:::sns:publish.waitForTaskToken"
                      Type     = "Task"
                    },
                    "Rollback Approval Results" = {
                      Choices = [
                        {
                          Next         = "Apply Rollback"
                          StringEquals = "Approve"
                          Variable     = "$.Status"
                        },
                        {
                          Next         = "Reject Rollback"
                          StringEquals = "Reject"
                          Variable     = "$.Status"
                        }
                      ]
                      Type = "Choice"
                    },
                    "Apply Rollback" = {
                      End = true
                      Parameters = {
                        EnvironmentVariablesOverride = [
                          {
                            Name      = "PATH"
                            Type      = "PLAINTEXT"
                            "Value.$" = "$.Path"
                          },
                          {
                            Name  = "COMMAND"
                            Type  = "PLAINTEXT"
                            Value = "apply"
                          },
                          {
                            Name  = "EXTRA_ARGS"
                            Type  = "PLAINTEXT"
                            Value = "-auto-approve"
                          }
                        ]
                        ProjectName = var.build_name
                      }
                      Resource = "arn:aws:states:::codebuild:startBuild.sync"
                      Type     = "Task"
                    },
                    "Reject Rollback" = {
                      Cause = "Terraform plan was rejected"
                      Error = "RejectedPlan"
                      Type  = "Fail"
                    }
                  }
                }
              }
            }
          }
        }
    })
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
      },
      {
        name  = "DOMAIN_NAME"
        value = aws_simpledb_domain.queue.id
        type  = "PLAINTEXT"
      },
      {
        name  = "TERRAGRUNT_WORKING_DIR"
        type  = "PLAINTEXT"
        value = var.terragrunt_parent_dir
      },
      {
        name  = "ACCOUNT_PARENT_PATHS"
        type  = "PLAINTEXT"
        value = join(",", var.account_parent_paths)
      }
    ]
  }

  role_policy_statements = [
    {
      sid       = "StepFunctionTriggerAccess"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = [aws_sfn_state_machine.this.arn]
    },
    {
      sid       = "SimpledbQueryAccess"
      effect    = "Allow"
      actions   = ["sdb:Select"]
      resources = ["arn:aws:sdb:${data.aws_region.current.name}:${var.account_id}:domain/${var.simpledb_name}"]
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
      sid     = "SNSAccess"
      effect  = "Allow"
      actions = ["sns:Publish"]
      resources = [
        aws_sns_topic.approval.arn
      ]
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