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
  value = aws_security_group.testing.id
}