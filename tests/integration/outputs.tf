output "repo_name" {
  value = github_repository.testing.name
}

output "state_machine_arn" {
  value = module.mut_infrastructure_live_ci.step_function_arn
}

output "state_machine_name" {
  value = module.mut_infrastructure_live_ci.step_function_name
}

output "merge_lock_github_webhook_id" {
  value     = module.mut_infrastructure_live_ci.merge_lock_github_webhook_id
  sensitive = true
}

output "merge_lock_ssm_key" {
  value = module.mut_infrastructure_live_ci.merge_lock_ssm_key
}

output "codebuild_create_deploy_stack_name" {
  value = module.mut_infrastructure_live_ci.codebuild_create_deploy_stack_name
}

output "codebuild_create_deploy_stack_arn" {
  value = module.mut_infrastructure_live_ci.codebuild_create_deploy_stack_arn
}

output "codebuild_terra_run_name" {
  value = module.mut_infrastructure_live_ci.codebuild_terra_run_name
}

output "codebuild_terra_run_arn" {
  value = module.mut_infrastructure_live_ci.codebuild_terra_run_arn
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

output "metadb_arn" {
  value = module.mut_infrastructure_live_ci.metadb_arn
}

output "metadb_name" {
  value = module.mut_infrastructure_live_ci.metadb_name
}

output "metadb_secret_manager_master_arn" {
  value = module.mut_infrastructure_live_ci.metadb_secret_manager_master_arn
}

output "voters" {
  value = local.voters
}

output "approval_url" {
  value = module.mut_infrastructure_live_ci.approval_url
}

output "trigger_sf_log_group_name" {
  value = module.mut_infrastructure_live_ci.trigger_sf_log_group_name
}

output "trigger_sf_function_name" {
  value = module.mut_infrastructure_live_ci.trigger_sf_function_name
}

output "approval_request_log_group_name" {
  value = module.mut_infrastructure_live_ci.approval_request_log_group_name
}

output "base_branch" {
  value = module.mut_infrastructure_live_ci.base_branch
}