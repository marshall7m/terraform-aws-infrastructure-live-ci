locals {
  trigger_sf_function_name = coalesce(var.trigger_sf_function_name, "${var.step_function_name}-trigger-sf")
  trigger_sf_dep_zip       = "${path.module}/trigger_sf_deps.zip"
  trigger_sf_dep_dir       = "${path.module}/functions/trigger_sf/deps"
}

data "archive_file" "lambda_trigger_sf" {
  type        = "zip"
  source_dir  = "${path.module}/functions/trigger_sf"
  output_path = "${path.module}/trigger_sf.zip"
}

resource "null_resource" "lambda_trigger_sf_deps" {
  triggers = {
    zip_hash = fileexists(local.trigger_sf_dep_zip) ? 0 : timestamp()
  }
  provisioner "local-exec" {
    command = "python3 -m pip install --upgrade pip && python3 -m pip install --upgrade --target ${local.trigger_sf_dep_dir}/python aurora-data-api==0.4.0 awscli==1.22.5 boto3==1.20.5"
  }
}

data "archive_file" "lambda_trigger_sf_deps" {
  type        = "zip"
  source_dir  = local.trigger_sf_dep_dir
  output_path = local.trigger_sf_dep_zip
  depends_on = [
    null_resource.lambda_trigger_sf_deps
  ]
}

module "lambda_trigger_sf" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_trigger_sf.output_path
  source_code_hash = data.archive_file.lambda_trigger_sf.output_base64sha256
  function_name    = local.trigger_sf_function_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  env_vars = {
    GITHUB_MERGE_LOCK_SSM_KEY = aws_ssm_parameter.merge_lock.name
    EVENTBRIDGE_FINISHED_RULE = var.github_token_ssm_key
    STATE_MACHINE_ARN         = local.state_machine_arn
    PGUSER                    = var.metadb_ci_username
    PGPORT                    = var.metadb_port
    METADB_NAME               = local.metadb_name
    METADB_CLUSTER_ARN        = aws_rds_cluster.metadb.arn
    METADB_SECRET_ARN         = aws_secretsmanager_secret_version.master_metadb_user.arn
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.merge_lock_ssm_param_access.arn,
    aws_iam_policy.ci_metadb_access.arn
  ]
  statements = [
    {
      sid    = "MetaDBAccess"
      effect = "Allow"
      actions = [
        "rds-data:ExecuteStatement",
        "rds-data:RollbackTransaction",
        "rds-data:CommitTransaction",
        "rds-data:BatchExecuteStatement",
        "rds-data:BeginTransaction"
      ]
      resources = [aws_rds_cluster.metadb.arn]
    },
    {
      sid    = "StateMachineAccess"
      effect = "Allow"
      actions = [
        "states:StartExecution",
        "states:ListExecutions"
      ]
      resources = [local.state_machine_arn]
    },
    {
      sid       = "StateMachineExecutionAccess"
      effect    = "Allow"
      actions   = ["states:StopExecution"]
      resources = ["arn:aws:states:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:execution:${var.step_function_name}:*"]
    }
  ]
  allowed_to_invoke = [
    {
      statement_id = "StepFunctionFinishedEvent"
      principal    = "events.amazonaws.com"
      arn          = aws_cloudwatch_event_rule.sf_execution.arn
    }
  ]
  lambda_layers = [
    {
      filename         = data.archive_file.lambda_trigger_sf_deps.output_path
      name             = "${local.trigger_sf_function_name}-deps"
      runtimes         = ["python3.8"]
      source_code_hash = data.archive_file.lambda_trigger_sf_deps.output_base64sha256
      description      = "Dependencies for lambda function: ${local.trigger_sf_function_name}"
    }
  ]
}