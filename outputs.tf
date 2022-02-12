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

output "codebuild_merge_lock_name" {
  value = module.codebuild_merge_lock.name
}

output "codebuild_merge_lock_arn" {
  value = module.codebuild_merge_lock.arn
}

output "sf_arn" {
  value = aws_sfn_state_machine.this.arn
}

output "metadb_ci_username" {
  value = var.metadb_ci_username
}

output "metadb_ci_password" {
  value = var.metadb_ci_username
  sensitive = true
}

output "metadb_secret_manager_master_arn" {
  value = aws_secretsmanager_secret_version.master_metadb_user.arn
}