locals {
  mut_id                = "mut-terraform-aws-infrastructure-live-ci"
  plan_role_name        = "${local.mut_id}-plan"
  deploy_role_name      = "${local.mut_id}-deploy"
  approval_key          = "approval"
  test_approval_content = false
  voters                = local.test_approval_content ? [data.aws_ssm_parameter.testing_sender_email.value] : ["success@simulator.amazonses.com"]
}

provider "aws" {
  alias = "secondary"
  assume_role {
    role_arn     = "arn:aws:iam::${data.aws_ssm_parameter.secondary_testing_account.value}:role/cross-account-admin-access"
    session_name = "${local.mut_id}-testing"
  }
}

data "aws_caller_identity" "current" {}

data "github_user" "current" {
  username = ""
}

data "aws_ssm_parameter" "testing_sender_email" {
  name = "testing-ses-email-address"
}

data "aws_ssm_parameter" "secondary_testing_account" {
  name = "secondary-testing-account-id"
}

resource "github_repository" "testing" {
  name        = local.mut_id
  description = "Test repo for mut: ${local.mut_id}"
  visibility  = "public"
  template {
    owner      = "marshall7m"
    repository = "infrastructure-live-testing-template"
  }
}

resource "aws_s3_bucket" "testing_tf_state" {
  bucket = "${local.mut_id}-tf-state"
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
      identifiers = ["arn:aws:iam::${data.aws_ssm_parameter.secondary_testing_account.value}:root"]
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
      identifiers = ["arn:aws:iam::${data.aws_ssm_parameter.secondary_testing_account.value}:root"]
    }
  }
}

resource "aws_s3_bucket_policy" "testing_tf_state" {
  bucket = aws_s3_bucket.testing_tf_state.id
  policy = data.aws_iam_policy_document.testing_tf_state.json
}

resource "random_password" "metadb" {
  for_each = toset(["master", "ci"])
  length   = 16
  special  = false
}

module "plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name = local.plan_role_name
  trusted_entities = [
    module.mut_infrastructure_live_ci.codebuild_create_deploy_stack_role_arn,
    module.mut_infrastructure_live_ci.codebuild_terra_run_role_arn
  ]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

module "deploy_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = local.deploy_role_name
  trusted_entities        = [module.mut_infrastructure_live_ci.codebuild_terra_run_role_arn]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

module "secondary_plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name = local.plan_role_name
  trusted_entities = [
    module.mut_infrastructure_live_ci.codebuild_create_deploy_stack_role_arn,
    module.mut_infrastructure_live_ci.codebuild_terra_run_role_arn
  ]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  providers = {
    aws = aws.secondary
  }
}

module "secondary_deploy_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
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

module "mut_infrastructure_live_ci" {
  source = "../.."

  repo_name   = local.mut_id
  base_branch = "master"

  metadb_publicly_accessible = true
  metadb_username            = "mut_user"
  metadb_password            = random_password.metadb["master"].result

  metadb_ci_username          = "mut_ci_user"
  metadb_ci_password          = random_password.metadb["ci"].result
  enable_metadb_http_endpoint = true

  #required specific testing repo to conditionally set the terraform backend configurations
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

  create_github_token_ssm_param = false
  github_token_ssm_key          = "admin-github-token"

  approval_request_sender_email = data.aws_ssm_parameter.testing_sender_email.value
  account_parent_cfg = [
    {
      name                = "dev"
      path                = "directory_dependency/dev-account"
      dependencies        = ["shared_services"]
      voters              = local.voters
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.plan_role_name}"
      deploy_role_arn     = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.deploy_role_name}"
    },
    {
      name                = "shared_services"
      path                = "directory_dependency/shared-services-account"
      dependencies        = []
      voters              = local.voters
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_ssm_parameter.secondary_testing_account.value}:role/${local.plan_role_name}"
      deploy_role_arn     = "arn:aws:iam::${data.aws_ssm_parameter.secondary_testing_account.value}:role/${local.deploy_role_name}"
    }
  ]

  depends_on = [
    github_repository.testing
  ]
}