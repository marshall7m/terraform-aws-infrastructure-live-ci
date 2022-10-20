output "repo_full_name" {
  value = github_repository.testing.full_name
}

output "repo_clone_url" {
  value = github_repository.testing.http_clone_url
}

output "repo_name" {
  value = github_repository.testing.name
}

output "state_machine_arn" {
  value = module.mut_infrastructure_live_ci.step_function_arn
}

output "state_machine_name" {
  value = module.mut_infrastructure_live_ci.step_function_name
}

output "github_webhook_id" {
  value     = module.mut_infrastructure_live_ci.github_webhook_id
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

output "plan_role_arn" {
  value = module.plan_role.role_arn
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

output "ecs_pr_plan_container_name" {
  value = module.mut_infrastructure_live_ci.ecs_pr_plan_container_name
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

output "ecs_apply_role_arn" {
  value = module.mut_infrastructure_live_ci.ecs_apply_role_arn
}

output "ecs_plan_role_arn" {
  value = module.mut_infrastructure_live_ci.ecs_plan_role_arn
}

output "email_approval_secret" {
  sensitive = true
  value     = module.mut_infrastructure_live_ci.email_approval_secret
}

output "ecs_subnet_ids" {
  value = module.mut_infrastructure_live_ci.ecs_subnet_ids
}

output "ecs_security_group_ids" {
  value = module.mut_infrastructure_live_ci.ecs_security_group_ids
}

output "aws_region" {
  value = data.aws_region.current.name
}

output "ecs_network_config" {
  value = module.mut_infrastructure_live_ci.ecs_network_config
}

output "create_deploy_stack_log_stream_prefix" {
  value = module.mut_infrastructure_live_ci.create_deploy_stack_log_stream_prefix
}

output "ecs_log_url_prefix" {
  value = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#logsV2:log-groups/log-group/${module.mut_infrastructure_live_ci.ecs_log_group_name}/log-events/"
}

output "commit_status_config" {
  value = module.mut_infrastructure_live_ci.commit_status_config
}

output "ecs_pr_plan_task_definition_arn" {
  value = module.mut_infrastructure_live_ci.ecs_pr_plan_task_definition_arn
}

output "apply_role_arn" {
  value = module.apply_role.role_arn
}

output "step_function_arn" {
  value = module.mut_infrastructure_live_ci.step_function_arn
}

output "step_function_name" {
  value = module.mut_infrastructure_live_ci.step_function_name
}

output "ecs_endpoint_url" {
  value = var.ecs_endpoint_url
}