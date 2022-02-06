output "repo_name" {
  value = github_repository.test.name
}

output "state_machine_arn" {
  value = module.mut_infrastructure_live_ci.sf_arn
}

output "codebuild_merge_lock_name" {
  value = module.mut_infrastructure_live_ci.codebuild_merge_lock_name
}

output "codebuild_merge_lock_arn" {
  value = module.mut_infrastructure_live_ci.codebuild_merge_lock_arn
}

output "codebuild_trigger_sf_name" {
  value = module.mut_infrastructure_live_ci.codebuild_trigger_sf_name
}

output "codebuild_trigger_sf_arn" {
  value = module.mut_infrastructure_live_ci.codebuild_trigger_sf_arn
}

output "pg_user" {
  value = module.mut_infrastructure_live_ci.metadb_username
}

output "pg_password" {
  value     = module.mut_infrastructure_live_ci.metadb_password
  sensitive = true
}

output "pg_database" {
  value = module.mut_infrastructure_live_ci.metadb_name
}

output "pg_host" {
  value = module.mut_infrastructure_live_ci.metadb_address
}

output "pg_port" {
  value = module.mut_infrastructure_live_ci.metadb_port
}

output "testing_ecs_cluster_arn" {
  value = aws_ecs_cluster.testing.arn
}

output "testing_ecs_task_arn" {
  value = aws_ecs_service.testing.task_definition
}

output "public_subnets_ids" {
  value = module.vpc.public_subnets
}

output "private_subnets_ids" {
  value = module.vpc.private_subnets
}

output "testing_ecs_security_group_id" {
  value = aws_security_group.testing_ecs.id
}

output "testing_efs_dns" {
  value = aws_efs_file_system.testing.dns_name
}

output "testing_efs_ip_address" {
  value = aws_efs_mount_target.testing.ip_address
}

output "testing_vpn_client_endpoint" {
  value = module.testing_vpn.vpn_endpoint_id
  sensitive = true
}

output "testing_vpn_private_key_content" {
  value = module.testing_vpn.vpn_client_key
  sensitive = true
}

output "testing_vpn_cert_content" {
  value = module.testing_vpn.vpn_client_cert
  sensitive = true
}