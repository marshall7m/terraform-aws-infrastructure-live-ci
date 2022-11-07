output "base_branch" {
  description = "Base branch for repository that all PRs will compare to"
  value       = var.base_branch
}

output "metadb_endpoint" {
  description = "AWS RDS endpoint for the metadb"
  value       = aws_rds_cluster.metadb.endpoint
}

output "metadb_username" {
  description = "Master username for the metadb"
  value       = aws_rds_cluster.metadb.master_username
}

output "metadb_password" {
  description = "Master password for the metadb"
  value       = aws_rds_cluster.metadb.master_password
  sensitive   = true
}

output "metadb_secret_manager_master_arn" {
  description = "Secret Manager ARN of the metadb master user credentials"
  value       = aws_secretsmanager_secret_version.master_metadb_user.arn
}

output "metadb_secret_manager_ci_arn" {
  description = "Secret Manager ARN of the metadb CI user credentials"
  value       = aws_secretsmanager_secret_version.ci_metadb_user.arn
}

output "metadb_port" {
  description = "Port used for the metadb"
  value       = aws_rds_cluster.metadb.port
}

output "metadb_name" {
  description = "Name of the metadb"
  value       = aws_rds_cluster.metadb.database_name
}

output "metadb_arn" {
  description = "ARN for the metadb"
  value       = aws_rds_cluster.metadb.arn
}

output "metadb_ci_username" {
  description = "Username used by CI services to connect to the metadb"
  value       = var.metadb_ci_username
}

output "metadb_ci_password" {
  description = "Password used by CI services to connect to the metadb"
  value       = var.metadb_ci_password
  sensitive   = true
}

output "ecs_cluster_arn" {
  description = "AWS ECS cluster ARN"
  value       = aws_ecs_cluster.this.arn
}

output "ecs_subnet_ids" {
  description = "AWS VPC subnets IDs that the ECS tasks will be hosted in"
  value       = var.ecs_subnet_ids
}

output "ecs_security_group_ids" {
  description = "List of security groups IDs used ECS tasks"
  value       = [aws_security_group.ecs_tasks.id]
}

output "ecs_create_deploy_stack_family" {
  description = "AWS ECS task definition family for the create deploy stack task"
  value       = aws_ecs_task_definition.create_deploy_stack.family
}

output "ecs_create_deploy_stack_container_name" {
  description = "Name of the create deploy stack ECS task container"
  value       = local.create_deploy_stack_container_name
}

output "ecs_create_deploy_stack_definition_arn" {
  description = "AWS ECS create deploy stack defintion ARN"
  value       = aws_ecs_task_definition.create_deploy_stack.arn
}

output "ecs_create_deploy_stack_role_arn" {
  description = "AWS ECS create deploy stack task IAM role ARN"
  value       = module.create_deploy_stack_role.role_arn
}

output "create_deploy_stack_status_check_name" {
  description = "Name of the create deploy stack GitHub commit status"
  value       = var.create_deploy_stack_status_check_name
}

output "scan_type_ssm_param_name" {
  description = "Name of the AWS SSM Parameter store value used to determine the scan type within the create deploy stack task"
  value       = aws_ssm_parameter.scan_type.name
}

output "ecs_apply_role_arn" {
  description = "IAM role ARN the AWS ECS terra run task can assume"
  value       = module.apply_role.role_arn
}

output "ecs_plan_role_arn" {
  description = "IAM role ARN the AWS ECS pr plan and terra run task can assume"
  value       = module.plan_role.role_arn
}

output "ecs_terra_run_task_definition_arn" {
  description = "AWS ECS terra run task defintion ARN"
  value       = aws_ecs_task_definition.terra_run.arn
}

output "ecs_terra_run_task_container_name" {
  description = "Name of the terra run ECS task container"
  value       = local.terra_run_container_name
}

output "ecs_pr_plan_task_definition_arn" {
  description = "AWS ECS terra run task defintion ARN"
  value       = aws_ecs_task_definition.plan.arn
}

output "ecs_pr_plan_container_name" {
  description = "Name of the pr plan ECS task container"
  value       = local.pr_plan_container_name
}

output "ecs_pr_plan_family" {
  description = "AWS ECS task definition family for the PR plan task"
  value       = aws_ecs_task_definition.plan.family
}

output "step_function_arn" {
  description = "ARN of the Step Function"
  value       = aws_sfn_state_machine.this.arn
}

output "step_function_name" {
  description = "Name of the Step Function"
  value       = aws_sfn_state_machine.this.name
}

output "approval_url" {
  description = "Lambda Function URL used for casting deployment approval votes"
  value       = module.lambda_approval_response.lambda_function_url
}

output "approval_response_function_name" {
  description = "Name of the Lambda Function used for handling approval responses"
  value       = module.lambda_approval_response.lambda_function_name
}

output "approval_response_role_arn" {
  description = "IAM Role ARN of the Lambda Function used for handling approval responses"
  value       = module.lambda_approval_response.lambda_role_arn
}

output "approval_request_log_group_name" {
  description = "Cloudwatch log group associated with the Lambda Function used for processing deployment approval responses"
  value       = module.lambda_approval_request.lambda_cloudwatch_log_group_name
}

output "approval_request_function_name" {
  description = "Name of the Lambda Function used for sending approval requests"
  value       = module.lambda_approval_request.lambda_function_name
}

output "github_webhook_id" {
  description = "GitHub webhook ID used for sending pull request activity to the Lambda Receiver Function"
  value       = github_repository_webhook.this.id
}

output "receiver_function_name" {
  description = "Name of the Lambda Receiver Function"
  value       = module.lambda_webhook_receiver.lambda_function_name
}

output "receiver_role_arn" {
  description = "ARN of the Lambda Receiver Function"
  value       = module.lambda_webhook_receiver.lambda_role_arn
}

output "merge_lock_status_check_name" {
  description = "Context name of the merge lock GitHub commit status check"
  value       = var.merge_lock_status_check_name
}

output "merge_lock_ssm_key" {
  description = "SSM Parameter Store key used for storing the current PR ID that has been merged and is being process by the CI flow"
  value       = aws_ssm_parameter.merge_lock.name
}

output "lambda_trigger_sf_arn" {
  description = "ARN of the Lambda Function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.lambda_function_arn
}

output "trigger_sf_log_group_name" {
  description = "Cloudwatch log group associated with the Lambda Function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.lambda_cloudwatch_log_group_name
}

output "trigger_sf_function_name" {
  description = "Name of the Lambda Function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.lambda_function_name
}


output "email_approval_secret" {
  description = "Secret value used for authenticating email approval responses"
  sensitive   = true
  value       = random_password.email_approval_secret.result
}

output "ecs_network_config" {
  description = "VPC network configurations for ECS tasks"
  value = {
    awsvpcConfiguration = local.ecs_network_config
  }
}

output "ecs_log_group_name" {
  description = "Cloudwatch log group name for all ECS tasks"
  value       = aws_cloudwatch_log_group.ecs_tasks.name
}

output "create_deploy_stack_log_stream_prefix" {
  description = "Create Deploy Stack Cloudwatch log stream prefix"
  value       = local.create_deploy_stack_log_stream_prefix
}

output "commit_status_config" {
  description = "Determines which commit statuses should be sent for each of the specified pipeline components"
  value       = local.commit_status_config
}

output "account_parent_cfg" {
  description = "AWS account-level configurations"
  value       = var.account_parent_cfg
}

output "file_path_pattern" {
  description = "Regex pattern to match webhook modified/new files to"
  value       = var.file_path_pattern
}

output "github_webhook_secret_ssm_key" {
  description = "Key for the AWS SSM Parameter Store used to store GitHub webhook secret"
  value       = aws_ssm_parameter.github_webhook_secret.name
}

output "approval_response_ses_secret" {
  description = "Secret value used for authenticating AWS SES approvals within the approval response Lambda Function"
  value       = aws_ssm_parameter.email_approval_secret.name
  sensitive   = true
}