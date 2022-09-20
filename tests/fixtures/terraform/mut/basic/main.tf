locals {
  mut_id          = "mut-${random_string.mut.id}"
  plan_role_name  = "${local.mut_id}-plan"
  apply_role_name = "${local.mut_id}-deploy"
}

data "aws_caller_identity" "current" {}

module "mut_infrastructure_live_ci" {
  source = "../../../../../../../..//"

  prefix = local.mut_id

  repo_clone_url = github_repository.testing.http_clone_url
  base_branch    = var.base_branch

  enforce_admin_branch_protection = var.enforce_admin_branch_protection

  commit_status_config = var.commit_status_config

  metadb_name         = var.metadb_name
  metadb_username     = var.metadb_username
  metadb_password     = random_password.metadb["master"].result
  metadb_ci_username  = var.metadb_ci_username
  metadb_ci_password  = random_password.metadb["ci"].result
  metadb_schema       = var.metadb_schema
  metadb_subnet_ids   = module.vpc.public_subnets
  metadb_endpoint_url = var.metadb_endpoint_url

  vpc_id         = module.vpc.vpc_id
  ecs_subnet_ids = module.vpc.public_subnets

  private_registry_auth          = true
  create_private_registry_secret = true
  registry_username              = var.registry_username
  registry_password              = var.registry_password
  ecs_image_address              = var.ecs_image_address

  # repo specific env vars required to conditionally set the terraform backend configurations
  ecs_tasks_common_env_vars = concat([
    {
      name  = "TG_BACKEND"
      value = "s3"
    },
    {
      name  = "TG_S3_BUCKET"
      value = aws_s3_bucket.testing_tf_state.id
    }
  ], local.local_task_common_env_vars)

  tf_state_read_access_policy = aws_iam_policy.trigger_sf_tf_state_access.arn

  create_github_token_ssm_param = var.create_github_token_ssm_param
  github_token_ssm_value        = var.github_token_ssm_value

  approval_request_sender_email = var.approval_request_sender_email
  send_verification_email       = var.send_verification_email

  approval_sender_arn           = var.approval_sender_arn
  create_approval_sender_policy = var.create_approval_sender_policy
  metadb_subnet_group_name      = var.metadb_subnet_group_name
  create_metadb_subnet_group    = var.create_metadb_subnet_group

  account_parent_cfg = [
    {
      name                = "dev"
      path                = "directory_dependency/dev-account"
      dependencies        = ["shared_services"]
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.plan_role_name}"
      apply_role_arn      = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.apply_role_name}"
    },
    {
      name                = "shared_services"
      path                = "directory_dependency/shared-services-account"
      dependencies        = []
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.plan_role_name}"
      apply_role_arn      = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.apply_role_name}"
    }
  ]

  # for some reason an explicit dependency is needed for github_repository.testing or else a repo not found error is raised
  # when the module resources access github_repository attributes
  depends_on = [
    github_repository.testing
  ]
}