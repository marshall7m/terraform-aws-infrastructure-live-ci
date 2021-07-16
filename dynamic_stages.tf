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
    StartAt = var.account_parent_cfg[0].name
    States = { for i in range(length(var.account_parent_cfg)) : var.account_parent_cfg[i].name => {
      Type                                                     = "Parallel"
      "${can(var.account_parent_cfg[i + 1]) ? "Next" : "End"}" = can(var.account_parent_cfg[i + 1]) ? var.account_parent_cfg[i + 1].name : true
      Branches = [for account in var.account_parent_cfg[i].paths : {
        StartAt = "${account}"
        States = {
          "${account}" = {
            Type           = "Map"
            MaxConcurrency = 0
            End            = true
            ItemsPath      = "$.${account}.RunOrder"
            Iterator = {
              StartAt = "${account}: Deploy"
              States = {
                "${account}: Deploy" = {
                  Type           = "Map"
                  MaxConcurrency = 1
                  Parameters = {
                    "Path.$" = "$$.Map.Item.Value"
                  }
                  End = true
                  Iterator = {
                    StartAt = "Account: ${account}"
                    States = {
                      "Account: ${account}" : {
                        "Type" : "Pass",
                        "Next" : "${account}: Get Rollback Providers"
                      }
                      "${account}: Get Rollback Providers" = {
                        Type     = "Task"
                        Resource = "arn:aws:states:::codebuild:startBuild.sync"
                        Parameters = {
                          SourceVersion = "$.source_version"
                          EnvironmentVariablesOverride = [
                            {
                              Name      = "PATH"
                              Type      = "PLAINTEXT"
                              "Value.$" = "$.Path"
                            }
                          ]
                          ProjectName = var.get_rollback_providers_build_name
                        }
                        ResultPath = "$.rollback_provider_flags"
                        Next       = "${account}: Plan"
                      },
                      "${account}: Plan" = {
                        Next = "${account}: Request Approval"
                        Parameters = {
                          SourceVersion = "$.source_version"
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
                      "${account}: Request Approval" = {
                        Next = "${account}: Approval Results"
                        Parameters = {
                          FunctionName = module.lambda_approval_request.function_arn
                          Payload = {
                            StateMachine         = "$$.StateMachine.Id"
                            ExecutionId          = "$$.Execution.Id"
                            TaskToken            = "$$.Task.Token"
                            TargetEmailAddresses = "${var.account_parent_cfg[i].approval_emails}"
                          }
                        }
                        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
                        Type     = "Task"
                      },
                      "${account}: Approval Results" = {
                        Choices = [
                          {
                            Next         = "${account}: Apply"
                            StringEquals = "Approve"
                            Variable     = "$.Status"
                          },
                          {
                            Next         = "${account}: Reject"
                            StringEquals = "Reject"
                            Variable     = "$.Status"
                          }
                        ]
                        Type = "Choice"
                      },
                      "${account}: Apply" = {
                        End = true
                        Parameters = {
                          SourceVersion = "$.source_version"
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
                        Catch = [
                          {
                            ErrorEquals = ["States.TaskFailed"]
                            Next        = "${account}: New Providers?"
                          }
                        ]
                      },
                      "${account}: Reject" = {
                        Cause = "Terraform plan was rejected"
                        Error = "RejectedPlan"
                        Type  = "Fail"
                      },
                      "${account}: New Providers?" = {
                        Choices = [
                          {
                            Next     = "${account}: Rollback New Providers"
                            IsNull   = false
                            Variable = "$.rollback_provider_flags"
                          },
                          {
                            Next     = "${account}: Apply Rollback"
                            IsNull   = true
                            Variable = "$.rollback_provider_flags"
                          }
                        ]
                        Type = "Choice"
                      },
                      "${account}: Rollback New Providers" = {
                        Next = "${account}: Apply Rollback"
                        Parameters = {
                          SourceVersion = "$.source_version"
                          EnvironmentVariablesOverride = [
                            {
                              Name      = "PATH"
                              Type      = "PLAINTEXT"
                              "Value.$" = "$.Path"
                            },
                            {
                              Name  = "COMMAND"
                              Type  = "PLAINTEXT"
                              Value = "destroy -auto-approve"
                            },
                            {
                              Name  = "EXTRA_ARGS"
                              Type  = "PLAINTEXT"
                              Value = "$.rollback_provider_flags"
                            }
                          ]
                          ProjectName = var.get_rollback_providers_build_name
                        }
                        Resource = "arn:aws:states:::codebuild:startBuild.sync"
                        Type     = "Task"
                      },
                      "${account}: Apply Rollback" = {
                        End = true
                        Parameters = {
                          SourceVersion = "$.rollback_source_version"
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
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }]
    } }
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
      resources = [module.codebuild_deployment_run_order.arn]
    }
  ]
}

resource "aws_cloudwatch_event_target" "sf" {
  rule      = aws_cloudwatch_event_rule.this.name
  target_id = "CodeBuildTriggerStepFunction"
  arn       = module.codebuild_deployment_run_order.arn
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

module "codebuild_deployment_run_order" {
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
        value = join(",", flatten(var.account_parent_cfg[*].paths))
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