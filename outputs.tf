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

output "ecs_plan_role_arn" {
  description = "ECS plan task IAM role ARN"
  value       = module.plan_role.role_arn
}

output "ecs_cluster_arn" {
  description = "AWS ECS cluster ARN"
  value       = aws_ecs_cluster.this.arn
}

output "ecs_create_deploy_stack_family" {
  description = "AWS ECS task definition family for the create deploy stack task"
  value       = aws_ecs_task_definition.create_deploy_stack.family
}

output "ecs_create_deploy_stack_role_arn" {
  description = "AWS ECS create deploy stack task IAM role ARN"
  value       = module.create_deploy_stack_role.role_arn
}

output "create_deploy_stack_status_check_name" {
  description = "Name of the create deploy stack GitHub commit status"
  value       = var.create_deploy_stack_status_check_name
}

output "ecs_terra_run_role_arn" {
  description = "AWS ECS terra run task IAM role ARN"
  value       = module.terra_run_role.role_arn
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
  description = "API URL used for requesting deployment approvals"
  value       = local.approval_url
}

output "approval_request_log_group_name" {
  description = "Cloudwatch log group associated with the Lambda Function used for processing deployment approval responses"
  value       = module.lambda_approval_request.cw_log_group_name
}

output "approval_request_function_name" {
  description = "Name of the Lambda Function used for sending approval requests"
  value       = module.lambda_approval_request.function_name
}

output "merge_lock_github_webhook_id" {
  description = "GitHub webhook ID used for sending pull request activity to the API to be processed by the merge lock Lambda Function"
  value       = module.github_webhook_validator.webhook_ids[var.repo_name]
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
  value       = module.lambda_trigger_sf.function_arn
}

output "trigger_sf_log_group_name" {
  description = "Cloudwatch log group associated with the Lambda Function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.cw_log_group_name
}

output "trigger_sf_function_name" {
  description = "Name of the Lambda Function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.function_name
}


