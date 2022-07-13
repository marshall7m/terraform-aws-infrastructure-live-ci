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

output "merge_lock_status_check_name" {
  value = module.mut_infrastructure_live_ci.merge_lock_status_check_name
}

output "merge_lock_ssm_key" {
  value = module.mut_infrastructure_live_ci.merge_lock_ssm_key
}

output "metadb_schema" {
  value = var.metadb_schema
}

output "metadb_arn" {
  value = module.mut_infrastructure_live_ci.metadb_arn
}

output "metadb_username" {
  value = module.mut_infrastructure_live_ci.metadb_username
}

output "metadb_name" {
  value = module.mut_infrastructure_live_ci.metadb_name
}

output "metadb_secret_manager_master_arn" {
  value = module.mut_infrastructure_live_ci.metadb_secret_manager_master_arn
}

output "metadb_secret_manager_ci_arn" {
  value = module.mut_infrastructure_live_ci.metadb_secret_manager_ci_arn
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

output "approval_request_function_name" {
  value = module.mut_infrastructure_live_ci.approval_request_function_name
}

output "base_branch" {
  value = module.mut_infrastructure_live_ci.base_branch
}

output "primary_test_plan_role_arn" {
  value = module.plan_role.role_arn
}

output "secondary_test_plan_role_arn" {
  value = module.secondary_plan_role.role_arn
}

output "ecs_cluster_arn" {
  value = module.mut_infrastructure_live_ci.ecs_cluster_arn
}

output "ecs_create_deploy_stack_family" {
  value = module.mut_infrastructure_live_ci.ecs_create_deploy_stack_family
}

output "ecs_create_deploy_stack_container_name" {
  value = module.mut_infrastructure_live_ci.ecs_create_deploy_stack_container_name
}

output "ecs_create_deploy_stack_role_arn" {
  value = module.mut_infrastructure_live_ci.ecs_create_deploy_stack_role_arn
}

output "scan_type_ssm_param_name" {
  value = module.mut_infrastructure_live_ci.scan_type_ssm_param_name
}

output "create_deploy_stack_status_check_name" {
  value = module.mut_infrastructure_live_ci.create_deploy_stack_status_check_name
}

output "ecs_create_deploy_stack_definition_arn" {
  value = module.mut_infrastructure_live_ci.ecs_create_deploy_stack_definition_arn
}

output "ecs_terra_run_task_definition_arn" {
  value = module.mut_infrastructure_live_ci.ecs_terra_run_task_definition_arn
}

output "ecs_terra_run_task_container_name" {
  value = module.mut_infrastructure_live_ci.ecs_terra_run_task_container_name
}

output "ecs_private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "ecs_security_group_ids" {
  value = [aws_security_group.ecs_tasks.id]
}

output "ecs_apply_role_arn" {
  value = module.mut_infrastructure_live_ci.ecs_apply_role_arn
}

output "ecs_plan_role_arn" {
  value = module.mut_infrastructure_live_ci.ecs_plan_role_arn
}