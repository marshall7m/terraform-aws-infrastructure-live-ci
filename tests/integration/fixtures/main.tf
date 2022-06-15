locals {
  mut_id                  = "mut-${random_string.mut.id}"
  plan_role_name          = "${local.mut_id}-plan"
  deploy_role_name        = "${local.mut_id}-deploy"
  metadb_testing_username = "integration_testing_user"
  metadb_testing_user_setup_script = templatefile("${path.module}/sql/metadb_testing_user_setup_script.sh", {
    cluster_arn = module.mut_infrastructure_live_ci.metadb_arn
    secret_arn  = module.mut_infrastructure_live_ci.metadb_secret_manager_master_arn
    db_name     = module.mut_infrastructure_live_ci.metadb_name
    create_testing_user_sql = templatefile("${path.module}/sql/create_metadb_testing_user.sql", {
      metadb_testing_username = local.metadb_testing_username
      metadb_testing_password = random_password.metadb["testing"].result
      metadb_username         = module.mut_infrastructure_live_ci.metadb_username
      metadb_name             = module.mut_infrastructure_live_ci.metadb_name
      metadb_schema           = var.metadb_schema
    })
  })
}

provider "aws" {
  alias = "secondary"
  assume_role {
    role_arn     = "arn:aws:iam::${var.testing_secondary_aws_account_id}:role/cross-account-admin-access"
    session_name = "${local.mut_id}-testing"
  }
}

data "aws_caller_identity" "current" {}

data "github_user" "current" {
  username = ""
}

resource "github_repository" "testing" {
  name        = local.mut_id
  description = "Test repo for mut: ${local.mut_id}"
  # TODO: Test with `visibility  = "private"` and `var.enable_branch_protection = true`
  # In order to enable branch protection for a private repo within the TF module, 
  # GitHub Pro account must be used for the provider
  visibility = "public"
  template {
    owner      = "marshall7m"
    repository = "infrastructure-live-testing-template"
  }
}

resource "aws_s3_bucket" "testing_tf_state" {
  bucket        = "${local.mut_id}-tf-state"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "testing_tf_state" {
  bucket = aws_s3_bucket.testing_tf_state.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "testing_tf_state" {
  bucket = aws_s3_bucket.testing_tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "testing_tf_state" {
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:PutObjectAcl",
    ]
    resources = ["${aws_s3_bucket.testing_tf_state.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.testing_secondary_aws_account_id}:root"]
    }
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:GetBucketVersioning"
    ]
    resources = [aws_s3_bucket.testing_tf_state.arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.testing_secondary_aws_account_id}:root"]
    }
  }
}

resource "aws_s3_bucket_policy" "testing_tf_state" {
  bucket = aws_s3_bucket.testing_tf_state.id
  policy = data.aws_iam_policy_document.testing_tf_state.json
}

resource "random_string" "mut" {
  length  = 8
  lower   = true
  upper   = false
  special = false
}

resource "random_password" "metadb" {
  for_each = toset(["master", "ci", "testing"])
  length   = 16
  special  = false
}

module "plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name = local.plan_role_name
  trusted_entities = [
    module.mut_infrastructure_live_ci.codebuild_create_deploy_stack_role_arn,
    module.mut_infrastructure_live_ci.codebuild_terra_run_role_arn,
    module.mut_infrastructure_live_ci.codebuild_pr_plan_role_arn
  ]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

module "deploy_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name               = local.deploy_role_name
  trusted_entities        = [module.mut_infrastructure_live_ci.codebuild_terra_run_role_arn]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

module "secondary_plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name = local.plan_role_name
  trusted_entities = [
    module.mut_infrastructure_live_ci.codebuild_create_deploy_stack_role_arn,
    module.mut_infrastructure_live_ci.codebuild_terra_run_role_arn,
    module.mut_infrastructure_live_ci.codebuild_pr_plan_role_arn
  ]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  providers = {
    aws = aws.secondary
  }
}

module "secondary_deploy_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name               = local.deploy_role_name
  trusted_entities        = [module.mut_infrastructure_live_ci.codebuild_terra_run_role_arn]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
  providers = {
    aws = aws.secondary
  }
}

data "aws_iam_policy_document" "trigger_sf_tf_state_access" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["${aws_s3_bucket.testing_tf_state.arn}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.testing_tf_state.arn}/*"]
  }
}

resource "aws_iam_policy" "trigger_sf_tf_state_access" {
  name        = "${local.mut_id}-tf-state-read-access"
  path        = "/"
  description = "Allows trigger_sf Codebuild project to read from terraform state S3 bucket"
  policy      = data.aws_iam_policy_document.trigger_sf_tf_state_access.json
}

resource "aws_secretsmanager_secret" "metadb_testing_user" {
  name = "${local.mut_id}-data-api-${local.metadb_testing_username}-credentials"
}

resource "aws_secretsmanager_secret_version" "metadb_testing_user" {
  secret_id = aws_secretsmanager_secret.metadb_testing_user.id
  secret_string = jsonencode({
    username = local.metadb_testing_username
    password = random_password.metadb["testing"].result
  })
}

resource "null_resource" "metadb_testing_user_setup" {
  provisioner "local-exec" {
    command     = local.metadb_testing_user_setup_script
    interpreter = ["bash", "-c"]
  }
  triggers = {
    metadb_testing_user_setup_script = sha256(local.metadb_testing_user_setup_script)
    cluster_arn                      = module.mut_infrastructure_live_ci.metadb_arn
    db_name                          = module.mut_infrastructure_live_ci.metadb_name
  }
}

module "mut_infrastructure_live_ci" {
  source = "../../..//"

  prefix = local.mut_id

  repo_name   = github_repository.testing.name
  base_branch = "master"
  # for testing purposes, admin is allowed to push to trunk branch for cleaning up 
  # testing changes without having to create a PR and triggering the entire CI pipeline
  enforce_admin_branch_protection = false

  metadb_username    = "mut_user"
  metadb_password    = random_password.metadb["master"].result
  metadb_ci_username = "mut_ci_user"
  metadb_ci_password = random_password.metadb["ci"].result
  metadb_schema      = var.metadb_schema
  # repo specific env vars required to conditionally set the terraform backend configurations
  codebuild_common_env_vars = [
    {
      name  = "TG_BACKEND"
      type  = "PLAINTEXT"
      value = "s3"
    },
    {
      name  = "TG_S3_BUCKET"
      type  = "PLAINTEXT"
      value = aws_s3_bucket.testing_tf_state.id
    }
  ]

  tf_state_read_access_policy = aws_iam_policy.trigger_sf_tf_state_access.arn

  create_merge_lock_github_token_ssm_param = true
  merge_lock_github_token_ssm_value        = var.merge_lock_github_token_ssm_value

  github_webhook_validator_github_token_ssm_value = var.github_webhook_validator_github_token_ssm_value

  approval_request_sender_email = var.approval_request_sender_email
  send_verification_email       = false

  account_parent_cfg = [
    {
      name                = "dev"
      path                = "directory_dependency/dev-account"
      dependencies        = ["shared_services"]
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.plan_role_name}"
      deploy_role_arn     = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.deploy_role_name}"
    },
    {
      name                = "shared_services"
      path                = "directory_dependency/shared-services-account"
      dependencies        = []
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${var.testing_secondary_aws_account_id}:role/${local.plan_role_name}"
      deploy_role_arn     = "arn:aws:iam::${var.testing_secondary_aws_account_id}:role/${local.deploy_role_name}"
    }
  ]

  depends_on = [
    github_repository.testing
  ]
}