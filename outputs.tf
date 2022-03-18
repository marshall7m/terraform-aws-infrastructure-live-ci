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

output "codebuild_trigger_sf_name" {
  value = module.codebuild_trigger_sf.name
}

output "codebuild_trigger_sf_arn" {
  value = module.codebuild_trigger_sf.arn
}

output "codebuild_trigger_sf_role_arn" {
  value = module.codebuild_trigger_sf.role_arn
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
  value = module.github_webhook_validator.webhook_ids[split("/", var.repo_full_name)[1]]
}

output "merge_lock_ssm_key" {
  value = aws_ssm_parameter.merge_lock.name
}