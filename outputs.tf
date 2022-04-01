output "metadb_endpoint" {
  value = aws_rds_cluster.metadb.endpoint
}

output "metadb_address" {
  value = aws_rds_cluster.metadb.endpoint
}

output "metadb_username" {
  value = aws_rds_cluster.metadb.master_username
}

output "metadb_password" {
  sensitive = true
  value     = aws_rds_cluster.metadb.master_password
}

output "metadb_port" {
  value = aws_rds_cluster.metadb.port
}

output "metadb_name" {
  value = aws_rds_cluster.metadb.database_name
}

output "metadb_arn" {
  value = aws_rds_cluster.metadb.arn
}

output "codebuild_create_deploy_stack_name" {
  value = module.codebuild_create_deploy_stack.name
}

output "codebuild_create_deploy_stack_arn" {
  value = module.codebuild_create_deploy_stack.arn
}

output "codebuild_create_deploy_stack_role_arn" {
  value = module.codebuild_create_deploy_stack.role_arn
}

output "codebuild_terra_run_name" {
  value = module.codebuild_terra_run.name
}

output "codebuild_terra_run_arn" {
  value = module.codebuild_terra_run.arn
}

output "codebuild_terra_run_role_arn" {
  value = module.codebuild_terra_run.role_arn
}

output "sf_arn" {
  value = aws_sfn_state_machine.this.arn
}

output "sf_name" {
  value = aws_sfn_state_machine.this.name
}

output "metadb_ci_username" {
  value = var.metadb_ci_username
}

output "metadb_ci_password" {
  value     = var.metadb_ci_username
  sensitive = true
}

output "metadb_secret_manager_master_arn" {
  value = aws_secretsmanager_secret_version.master_metadb_user.arn
}

output "approval_url" {
  value = local.approval_url
}

output "cw_rule_initiator" {
  value = local.cw_rule_initiator
}

output "merge_lock_github_webhook_id" {
  value = module.github_webhook_validator.webhook_ids[var.repo_name]
}

output "merge_lock_ssm_key" {
  value = aws_ssm_parameter.merge_lock.name
}

output "lambda_trigger_sf_arn" {
  value = module.lambda_trigger_sf.function_arn
}

output "trigger_sf_log_group_name" {
  value = module.lambda_trigger_sf.cw_log_group_name
}

output "approval_request_log_group_name" {
  value = module.lambda_approval_request.cw_log_group_name
}