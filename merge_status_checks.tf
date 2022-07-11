locals {
  webhook_receiver_name = "${var.prefix}-webhook-receiver"
  webhook_receiver_zip  = "${path.module}/webhook_receiver_deps.zip"
  webhook_receiver_dir  = "${path.module}/functions/webhook_receiver"

  trigger_pr_plan_name     = "${var.prefix}-trigger-pr-plan"
  trigger_pr_plan_deps_zip = "${path.module}/trigger_pr_plan_deps.zip"
  trigger_pr_plan_deps_dir = "${path.module}/functions/trigger_pr_plan/deps"

  github_webhook_validator_function_name = "${var.prefix}-webhook-validator"
}


module "github_webhook_validator" {
  # source = "github.com/marshall7m/terraform-aws-github-webhook?ref=v0.1.3"
  source = "github.com/marshall7m/terraform-aws-github-webhook"

  deployment_triggers = {
    approval = filesha1("${path.module}/approval.tf")
  }
  async_lambda_invocation = true

  create_api       = false
  api_id           = aws_api_gateway_rest_api.this.id
  root_resource_id = aws_api_gateway_rest_api.this.root_resource_id
  execution_arn    = aws_api_gateway_rest_api.this.execution_arn

  stage_name    = var.api_stage_name
  function_name = local.github_webhook_validator_function_name

  github_secret_ssm_key = "${local.github_webhook_validator_function_name}-secret"

  lambda_destination_on_success    = module.lambda_webhook_receiver.function_arn
  lambda_attach_async_event_policy = true
  lambda_create_async_event_config = true

  repos = [
    {
      name                          = var.repo_name
      is_private                    = true
      create_github_token_ssm_param = false
      github_token_ssm_param_arn    = local.github_token_arn
      filter_groups = [
        [
          {
            type    = "event"
            pattern = "pull_request"
          },
          {
            type    = "pr_action"
            pattern = "(opened|edited|reopened)"
          },
          {
            type    = "file_path"
            pattern = var.file_path_pattern
          },
          {
            type    = "base_ref"
            pattern = var.base_branch
          }
        ],
        [
          {
            type    = "event"
            pattern = "pull_request"
          },
          {
            type    = "pr_action"
            pattern = "(closed)"
          },
          {
            type    = "pull_request.merged"
            pattern = "True"
          },
          {
            type    = "file_path"
            pattern = var.file_path_pattern
          },
          {
            type    = "base_ref"
            pattern = var.base_branch
          }
        ]
      ]
    }
  ]
  # approval api resources needs to be created before this module since the module manages the deployment of the api
  depends_on = [
    aws_api_gateway_resource.approval,
    aws_api_gateway_integration.approval,
    aws_api_gateway_method.approval
  ]
}

resource "aws_ssm_parameter" "merge_lock" {
  name        = local.webhook_receiver_name
  description = "Locks PRs with infrastructure changes from being merged into base branch"
  type        = "String"
  value       = "none"
}


data "archive_file" "lambda_webhook_receiver" {
  type        = "zip"
  source_dir  = local.webhook_receiver_dir
  output_path = local.webhook_receiver_zip
}

resource "null_resource" "lambda_webhook_receiver_deps" {
  triggers = {
    zip_hash = fileexists(local.webhook_receiver_zip) ? 0 : timestamp()
  }
  provisioner "local-exec" {
    command = "pip install --target ${local.webhook_receiver_dir} requests==2.27.1 PyGithub==1.54.1"
  }
}

module "lambda_webhook_receiver" {
  source           = "github.com/marshall7m/terraform-aws-lambda?ref=v0.1.5"
  filename         = data.archive_file.lambda_webhook_receiver.output_path
  source_code_hash = data.archive_file.lambda_webhook_receiver.output_base64sha256
  function_name    = local.webhook_receiver_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  timeout          = 120
  env_vars = {
    GITHUB_TOKEN_SSM_KEY         = local.github_token_ssm_key
    COMMIT_STATUS_CONFIG_SSM_KEY = local.commit_status_config_name

    ECS_CLUSTER_ARN = aws_ecs_cluster.this.arn
    ECS_NETWORK_CONFIG = jsonencode({
      awsvpcConfiguration = {
        subnets        = var.ecs_private_subnet_ids
        securityGroups = var.ecs_security_group_ids
      }
    })

    MERGE_LOCK_SSM_KEY           = aws_ssm_parameter.merge_lock.name
    MERGE_LOCK_STATUS_CHECK_NAME = var.merge_lock_status_check_name

    PR_PLAN_TASK_DEFINITION_ARN = aws_ecs_task_definition.plan.arn
    PR_PLAN_TASK_CONTAINER_NAME = local.pr_plan_container_name

    CREATE_DEPLOY_STACK_TASK_DEFINITION_ARN   = aws_ecs_task_definition.create_deploy_stack.arn
    CREATE_DEPLOY_STACK_COMMIT_STATUS_CONTEXT = var.create_deploy_stack_status_check_name
    CREATE_DEPLOY_STACK_TASK_CONTAINER_NAME   = local.create_deploy_stack_container_name

    ACCOUNT_DIM = jsonencode(var.account_parent_cfg)
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.commit_status_config.arn
  ]
  allowed_to_invoke = [
    {
      principal = "lambda.amazonaws.com"
      arn       = "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:function:${local.github_webhook_validator_function_name}"
    }
  ]

  statements = [
    {
      effect    = "Allow"
      actions   = ["ssm:DescribeParameters"]
      resources = ["*"]
    },
    {
      sid       = "SSMParamMergeLockReadAccess"
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = [aws_ssm_parameter.merge_lock.arn]
    },
    {
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
        aws_ecs_task_definition.plan.arn,
        aws_ecs_task_definition.create_deploy_stack.arn
      ]
    },
    {
      effect = "Allow"
      actions = [
        "ecs:DescribeTaskDefinition"
      ]
      resources = ["*"]
    },
    {
      effect = "Allow"
      actions = [
        "iam:PassRole"
      ]
      resources = [
        module.ecs_execution_role.role_arn,
        module.plan_role.role_arn,
        module.create_deploy_stack_role.role_arn
      ]
    }
  ]
}

resource "github_branch_protection" "merge_lock" {
  count         = var.enable_branch_protection ? 1 : 0
  repository_id = var.repo_name

  pattern          = var.base_branch
  enforce_admins   = var.enforce_admin_branch_protection
  allows_deletions = true

  required_status_checks {
    strict   = false
    contexts = [var.merge_lock_status_check_name]
  }

  dynamic "required_pull_request_reviews" {
    for_each = var.pr_approval_count != null ? [1] : []
    content {
      dismiss_stale_reviews           = true
      required_approving_review_count = var.pr_approval_count
    }
  }
}