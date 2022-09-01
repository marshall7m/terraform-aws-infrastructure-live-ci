locals {
  plan_role_name   = "${var.mut_id}-plan"
  deploy_role_name = "${var.mut_id}-deploy"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "github_user" "current" {
  username = ""
}

resource "github_repository" "testing" {
  name        = var.mut_id
  description = "Test repo for mut: ${var.mut_id}"
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
  bucket        = "${var.mut_id}-tf-state"
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
    module.mut_infrastructure_live_ci.ecs_create_deploy_stack_role_arn,
    module.mut_infrastructure_live_ci.ecs_plan_role_arn
  ]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

module "deploy_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name               = local.deploy_role_name
  trusted_entities        = [module.mut_infrastructure_live_ci.ecs_apply_role_arn]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
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
  name        = "${var.mut_id}-tf-state-read-access"
  path        = "/"
  description = "Allows ECS tasks to read from terraform state S3 bucket"
  policy      = data.aws_iam_policy_document.trigger_sf_tf_state_access.json
}

# test VPC used for hosting ECS tasks
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.14.2"

  name = var.mut_id
  cidr = "10.0.0.0/16"

  azs            = ["${data.aws_region.current.name}a", "${data.aws_region.current.name}b"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  create_igw           = true
  enable_dns_hostnames = true
  enable_dns_support   = true
}

module "mut_infrastructure_live_ci" {
  source = "../../..//"

  prefix = var.mut_id

  repo_name   = github_repository.testing.name
  base_branch = "master"
  # for testing purposes, admin is allowed to push to trunk branch for cleaning up 
  # testing changes without having to create a PR and triggering the entire CI pipeline
  enforce_admin_branch_protection = false

  # send all commit statuses so that the commit statuse state
  # can be used for e2e testing assertions
  # eliminates need to try pin point the exact task instance via parsing
  # with boto3 ecs list command
  # the commit status state is a valid reflection of if the process succeeded or not
  # since the commit status state takes into account all workload errors with the 
  # exception of the actual commit status failing to be sent which should be easy
  # to identify
  commit_status_config = {
    PrPlan            = true
    CreateDeployStack = true
    Plan              = true
    Apply             = true
    Execution         = true
  }

  metadb_name         = var.metadb_name
  metadb_username     = var.metadb_username
  metadb_password     = random_password.metadb["master"].result
  metadb_ci_username  = "mut_ci_user"
  metadb_ci_password  = random_password.metadb["ci"].result
  metadb_schema       = "testing"
  metadb_subnet_ids   = module.vpc.public_subnets
  metadb_endpoint_url = var.metadb_endpoint_url

  vpc_id         = module.vpc.vpc_id
  ecs_subnet_ids = module.vpc.public_subnets

  private_registry_auth          = true
  create_private_registry_secret = true
  registry_username              = "mock-registry-username"
  registry_password              = "mock-registry-password"
  ecs_image_address              = "terraform-aws-infrastructure-live/tasks:latest"

  # repo specific env vars required to conditionally set the terraform backend configurations
  ecs_tasks_common_env_vars = [
    {
      name  = "TG_BACKEND"
      value = "s3"
    },
    {
      name  = "TG_S3_BUCKET"
      value = aws_s3_bucket.testing_tf_state.id
    }
  ]

  tf_state_read_access_policy = aws_iam_policy.trigger_sf_tf_state_access.arn

  create_github_token_ssm_param = true
  github_token_ssm_value        = var.github_token_ssm_value

  approval_request_sender_email = "fakesender@fake.com"
  send_verification_email       = false

  approval_sender_arn           = "arn:aws:ses:us-east-1:123456789012:identity/fakesender@fake.com"
  create_approval_sender_policy = false
  metadb_subnet_group_name      = "foo"
  create_metadb_subnet_group    = false

  account_parent_cfg = [
    {
      name                = "dev"
      path                = "directory_dependency/dev-account"
      dependencies        = ["shared_services"]
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.plan_role_name}"
      apply_role_arn      = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.deploy_role_name}"
    },
    {
      name                = "shared_services"
      path                = "directory_dependency/shared-services-account"
      dependencies        = []
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.plan_role_name}"
      apply_role_arn      = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.deploy_role_name}"
    }
  ]

  depends_on = [
    github_repository.testing
  ]
}