locals {
  trigger_sf_function_name = "${var.prefix}-trigger-sf"
}
data "aws_iam_policy_document" "trigger_sf" {
  statement {
    sid    = "StateMachineAccess"
    effect = "Allow"
    actions = [
      "states:StartExecution",
      "states:ListExecutions"
    ]
    resources = [local.state_machine_arn]
  }
  statement {
    sid       = "StateMachineExecutionAccess"
    effect    = "Allow"
    actions   = ["states:StopExecution"]
    resources = ["arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:execution:${local.step_function_name}:*"]
  }
}

resource "aws_iam_policy" "trigger_sf" {
  name        = "${local.trigger_sf_function_name}-sf-access"
  description = "Allows Lambda function to start and stop executions for the specified Step Function machine(s)"
  policy      = data.aws_iam_policy_document.trigger_sf.json
}

module "lambda_trigger_sf" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "3.3.1"

  function_name = local.trigger_sf_function_name
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  source_path = [
    {
      path             = "${path.module}/functions/trigger_sf"
      pip_requirements = true
    },
    {
      path          = "${path.module}/functions/common_lambda"
      prefix_in_zip = "common_lambda"
    }
  ]

  environment_variables = {
    GITHUB_MERGE_LOCK_SSM_KEY    = aws_ssm_parameter.merge_lock.name
    GITHUB_TOKEN_SSM_KEY         = local.github_token_ssm_key
    COMMIT_STATUS_CONFIG_SSM_KEY = local.commit_status_config_ssm_key
    REPO_FULL_NAME               = local.repo_full_name
    STATE_MACHINE_ARN            = local.state_machine_arn

    PGUSER             = var.metadb_ci_username
    PGPORT             = var.metadb_port
    METADB_NAME        = local.metadb_name
    AURORA_CLUSTER_ARN = aws_rds_cluster.metadb.arn
    AURORA_SECRET_ARN  = aws_secretsmanager_secret_version.ci_metadb_user.arn
  }

  allowed_triggers = {
    StepFunctionFinishedEvent = {
      principal  = "events.amazonaws.com"
      source_arn = aws_cloudwatch_event_rule.sf_execution.arn
    }
  }
  create_unqualified_alias_allowed_triggers = true
  publish                                   = true

  attach_policies               = true
  number_of_policies            = 6
  role_force_detach_policies    = true
  attach_cloudwatch_logs_policy = true
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.merge_lock_ssm_param_full_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.commit_status_config.arn,
    aws_iam_policy.trigger_sf.arn
  ]
  vpc_subnet_ids         = try(var.lambda_trigger_sf_vpc_config.subnet_ids, null)
  vpc_security_group_ids = try(var.lambda_trigger_sf_vpc_config.security_group_ids, null)
  attach_network_policy  = var.lambda_trigger_sf_vpc_config != null ? true : false
}