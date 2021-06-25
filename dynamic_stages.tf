locals {
  approval_msg = <<EOF
This is an email requiring an approval for a step functions execution
Check the following information and click "Approve" link if you want to approve

Step Function State Machine: {}
Execution ID: {}

Approve:
${aws_api_gateway_deployment.approval.invoke_url}${aws_api_gateway_stage.approval.stage_name}${aws_api_gateway_resource.approval.path}/execution?action=approve&ex={}&sm={}&taskToken={}

Reject:
${aws_api_gateway_deployment.approval.invoke_url}${aws_api_gateway_stage.approval.stage_name}${aws_api_gateway_resource.approval.path}/execution?action=reject&ex={}&sm={}&taskToken={}
  EOF

  message = jsonencode(<<EOF
States.Format('${local.approval_msg}',
  $$.StateMachine.Id,
  $$.Execution.Id,
  $$.StateMachine.Id,
  $$.Task.Token,
  $$.Execution.Id,
  $$.StateMachine.Id,
  $$.Task.Token
)
  EOF
  )
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

resource "aws_sfn_state_machine" "this" {
  name     = var.step_function_name
  role_arn = module.sf_role.role_arn

  definition = <<EOF
{
  "StartAt": "Parallelize Stack",
  "States": {
    "Parallelize Stack": {
      "Type": "Map",
      "End": true,
      "Catch": [
        {
          "ErrorEquals": ["States.TaskFailed", "RejectedPlan"],
          "Next": "Stack Rollback"
        }
      ],
      "Iterator": {
        "StartAt": "Deploy",
        "States": {
          "Deploy": {
            "Type": "Map",
            "Parameters": {
              "Path.$": "$$.Map.Item.Value"
            },
            "End": true,
            "Iterator": {
              "StartAt": "Plan",
              "States": {
                "Plan": {
                  "Type": "Task",
                  "Resource": "arn:aws:states:::codebuild:startBuild",
                  "Parameters": {
                    "ProjectName": "${var.build_name}",
                    "EnvironmentVariablesOverride": [
                      {
                        "Name": "PATH",
                        "Type": "PLAINTEXT",
                        "Value.$": "$.Path"
                      },
                      {
                        "Name": "COMMAND",
                        "Type": "PLAINTEXT",
                        "Value": "plan"
                      }
                    ]
                  },
                  "Next": "Request Approval"
                },
                "Request Approval": {
                  "Type": "Task",
                  "Resource": "arn:aws:states:::sns:publish.waitForTaskToken",
                  "Next": "Approval Results",
                  "Parameters": {
                    "TopicArn": "${aws_sns_topic.approval.arn}",
                    "Message.$": ${local.message}
                  }
                },
                "Approval Results": {
                  "Type": "Choice",
                  "Choices": [
                    {
                      "Variable": "$.Status",
                      "StringEquals": "Approve",
                      "Next": "Apply"
                    },
                    {
                      "Variable": "$.Status",
                      "StringEquals": "Reject",
                      "Next": "Rejected State"
                    }
                  ]
                },
                "Apply": {
                  "Type": "Task",
                  "Resource": "arn:aws:states:::codebuild:startBuild",
                  "Parameters": {
                    "ProjectName": "${var.build_name}",
                    "EnvironmentVariablesOverride": [
                      {
                        "Name": "PATH",
                        "Type": "PLAINTEXT",
                        "Value.$": "$.Path"
                      },
                      {
                        "Name": "COMMAND",
                        "Type": "PLAINTEXT",
                        "Value": "plan"
                      }
                    ]
                  },
                  "End": true
                },
                "Reject": {
                  "Type": "Fail",
                  "Cause": "Terraform plan was rejected",
                  "Error": "RejectedPlan"
                }
              }
            }
          }
        }
      }
    },
    "Stack Rollback": {
      "Type": "Map",
      "End": true,
      "Iterator": {
        "StartAt": "Deploy Rollback",
        "States": {
          "Deploy Rollback": {
            "Type": "Map",
            "Parameters": {
              "Path.$": "$$.Map.Item.Value"
            },
            "End": true,
            "Iterator": {
              "StartAt": "Get Rollback Providers",
              "States": {
                "Get Rollback Providers": {
                  "Type": "Task",
                  "Resource": "arn:aws:states:::codebuild:startBuild",
                  "Parameters": {
                      "ProjectName": "${var.rollback_provider_build_name}",
                      "EnvironmentVariablesOverride": [
                          {
                              "Name": "PATH",
                              "Type": "PLAINTEXT",
                              "Value.$": "$.Path"
                          }
                      ]
                  },
                  "Next": "Plan Rollback"
                },
                "Plan Rollback": {
                  "Type": "Task",
                  "Resource": "arn:aws:states:::codebuild:startBuild",
                  "Parameters": {
                    "ProjectName": "${var.build_name}",
                    "EnvironmentVariablesOverride": [
                      {
                        "Name": "PATH",
                        "Type": "PLAINTEXT",
                        "Value.$": "$.Path"
                      },
                      {
                        "Name": "COMMAND",
                        "Type": "PLAINTEXT",
                        "Value": "plan"
                      }
                    ]
                  },
                  "Next": "Approval Rollback"
                },
                "Approval Rollback": {
                  "Type": "Task",
                  "Resource": "${aws_sfn_activity.manual_approval.id}",
                  "Next": "Apply Rollback"
                },
                "Apply Rollback": {
                  "Type": "Task",
                  "Resource": "arn:aws:states:::codebuild:startBuild",
                  "Parameters": {
                    "ProjectName": "${var.build_name}",
                    "EnvironmentVariablesOverride": [
                      {
                        "Name": "PATH",
                        "Type": "PLAINTEXT",
                        "Value.$": "$.Path"
                      },
                      {
                        "Name": "COMMAND",
                        "Type": "PLAINTEXT",
                        "Value": "plan"
                      }
                    ]
                  },
                  "End": true
                }
              }
            }
          }
        }
      }
    }
  }
}
  EOF
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

  name = "trigger-sf"

  source_auth_token          = var.github_token_ssm_value
  source_auth_server_type    = "GITHUB"
  source_auth_type           = "PERSONAL_ACCESS_TOKEN"
  source_auth_ssm_param_name = var.github_token_ssm_key

  build_source = {
    type                = "GITHUB"
    buildspec           = "buildspec_trigger_sf.yaml"
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