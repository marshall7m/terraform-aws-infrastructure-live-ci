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

output "codebuild_pr_plan_name" {
  description = "Codebuild project name used for creating Terraform plans for new/modified configurations within PRs"
  value       = module.codebuild_pr_plan.name
}

output "codebuild_pr_plan_role_arn" {
  description = "IAM role ARN of the CodeBuild project that creates Terraform plans for new/modified configurations within PRs"
  value       = module.codebuild_pr_plan.role_arn
}

output "codebuild_create_deploy_stack_name" {
  description = "Name of the CodeBuild project that creates the deployment records within the metadb"
  value       = module.codebuild_create_deploy_stack.name
}

output "codebuild_create_deploy_stack_arn" {
  description = "ARN of the CodeBuild project that creates the deployment records within the metadb"
  value       = module.codebuild_create_deploy_stack.arn
}

output "codebuild_create_deploy_stack_role_arn" {
  description = "IAM role ARN of the CodeBuild project that creates the deployment records within the metadb"
  value       = module.codebuild_create_deploy_stack.role_arn
}

output "codebuild_terra_run_name" {
  description = "Name of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow"
  value       = module.codebuild_terra_run.name
}

output "codebuild_terra_run_arn" {
  description = "ARN of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow"
  value       = module.codebuild_terra_run.arn
}

output "codebuild_terra_run_role_arn" {
  description = "IAM role ARN of the CodeBuild project that runs Terragrunt plan/apply commands within the Step Function execution flow"
  value       = module.codebuild_terra_run.role_arn
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
  description = "Cloudwatch log group associated with the Lambda function used for processing deployment approval responses"
  value       = module.lambda_approval_request.cw_log_group_name
}

output "merge_lock_github_webhook_id" {
  description = "GitHub webhook ID used for sending pull request activity to the API to be processed by the merge lock Lambda function"
  value       = module.github_webhook_validator.webhook_ids[local.repo_name]
}

output "merge_lock_status_check_name" {
  description = "Context name of the merge lock GitHub status check"
  value       = var.merge_lock_status_check_name
}

output "merge_lock_ssm_key" {
  description = "SSM Parameter Store key used for storing the current PR ID that has been merged and is being process by the CI flow"
  value       = aws_ssm_parameter.merge_lock.name
}

output "lambda_trigger_sf_arn" {
  description = "ARN of the Lambda function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.function_arn
}

output "trigger_sf_log_group_name" {
  description = "Cloudwatch log group associated with the Lambda function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.cw_log_group_name
}

output "trigger_sf_function_name" {
  description = "Name of the Lambda function used for triggering Step Function execution(s)"
  value       = module.lambda_trigger_sf.function_name
}