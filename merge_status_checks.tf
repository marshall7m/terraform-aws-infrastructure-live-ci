locals {
  webhook_receiver_name         = "${var.prefix}-webhook-receiver"
  trigger_pr_plan_name          = "${var.prefix}-trigger-pr-plan"
  github_webhook_secret_ssm_key = "${local.webhook_receiver_name}-gh-secret"
}

resource "random_password" "github_webhook_secret" {
  length = 24
}
resource "aws_ssm_parameter" "github_webhook_secret" {
  name        = local.github_webhook_secret_ssm_key
  description = "Secret value used to authenticate GitHub webhook requests"
  type        = "SecureString"
  value       = random_password.github_webhook_secret.result
}

resource "github_repository_webhook" "this" {
  repository = var.repo_name

  configuration {
    url          = module.lambda_webhook_receiver.lambda_function_url
    content_type = "json"
    insecure_ssl = false
    secret       = random_password.github_webhook_secret.result
  }

  active = true
  events = ["pull_request"]
}

resource "aws_ssm_parameter" "merge_lock" {
  name        = local.webhook_receiver_name
  description = "Locks PRs with infrastructure changes from being merged into base branch"
  type        = "String"
  value       = "none"
}

data "aws_iam_policy_document" "webhook_receiver" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid     = "SSMParamAccess"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.merge_lock.arn,
      aws_ssm_parameter.github_webhook_secret.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecs:RunTask"
    ]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
    resources = [
      aws_ecs_task_definition.plan.arn,
      aws_ecs_task_definition.create_deploy_stack.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition"
    ]
    resources = ["*"]
  }

  statement {
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
}

resource "aws_iam_policy" "webhook_receiver" {
  name   = local.webhook_receiver_name
  policy = data.aws_iam_policy_document.webhook_receiver.json
}

module "lambda_webhook_receiver" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "3.3.1"

  function_name = local.webhook_receiver_name
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  timeout       = 120

  authorization_type         = "NONE"
  create_lambda_function_url = true

  source_path = [
    {
      path             = "${path.module}/functions/webhook_receiver"
      pip_requirements = true
    },
    {
      path          = "${path.module}/functions/common_lambda"
      prefix_in_zip = "common_lambda"
    }
  ]

  environment_variables = {
    GITHUB_TOKEN_SSM_KEY          = local.github_token_ssm_key
    GITHUB_WEBHOOK_SECRET_SSM_KEY = aws_ssm_parameter.github_webhook_secret.name
    COMMIT_STATUS_CONFIG_SSM_KEY  = local.commit_status_config_name
    FILE_PATH_PATTERN             = trimspace(var.file_path_pattern)
    BASE_BRANCH                   = var.base_branch

    ECS_CLUSTER_ARN = aws_ecs_cluster.this.arn
    ECS_NETWORK_CONFIG = jsonencode({
      awsvpcConfiguration = {
        subnets        = var.ecs_subnet_ids
        securityGroups = [aws_security_group.ecs_tasks.id]
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

  publish = true

  attach_policies               = true
  number_of_policies            = 4
  role_force_detach_policies    = true
  attach_cloudwatch_logs_policy = true
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.commit_status_config.arn,
    aws_iam_policy.webhook_receiver.arn
  ]
  vpc_subnet_ids         = try(var.lambda_webhook_receiver_vpc_config.subnet_ids, null)
  vpc_security_group_ids = try(var.lambda_webhook_receiver_vpc_config.security_group_ids, null)
  attach_network_policy  = var.lambda_webhook_receiver_vpc_config != null ? true : false
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