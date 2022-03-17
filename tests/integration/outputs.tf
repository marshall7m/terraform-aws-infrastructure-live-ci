output "repo_name" {
  value = github_repository.testing.name
}

output "state_machine_arn" {
  value = module.mut_infrastructure_live_ci.sf_arn
}

output "state_machine_name" {
  value = module.mut_infrastructure_live_ci.sf_name
}

# output "codebuild_merge_lock_name" {
#   value = module.mut_infrastructure_live_ci.codebuild_merge_lock_name
# }

# output "codebuild_merge_lock_arn" {
#   value = module.mut_infrastructure_live_ci.codebuild_merge_lock_arn
# }

output "merge_lock_github_webhook_id" {
  value     = module.mut_infrastructure_live_ci.merge_lock_github_webhook_id
  sensitive = true
}

output "codebuild_trigger_sf_name" {
  value = module.mut_infrastructure_live_ci.codebuild_trigger_sf_name
}

output "codebuild_trigger_sf_arn" {
  value = module.mut_infrastructure_live_ci.codebuild_trigger_sf_arn
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

output "cw_rule_initiator" {
  value = module.mut_infrastructure_live_ci.cw_rule_initiator
}