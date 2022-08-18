locals {
  mut_id           = "mut-${random_string.mut.id}"
  plan_role_name   = "${local.mut_id}-plan"
  deploy_role_name = "${local.mut_id}-deploy"

  docker_context = "${path.module}/../../../docker"
  trigger_file_paths = flatten([for p in [local.docker_context] : try(fileexists(p), false) ? [p] :
    # use formatlist() to join directory and file name list since fileset doesn't give full path
    formatlist("${p}/%s", fileset(p, "*"))
  ])
  full_image_url = coalesce(var.full_image_url, "ghcr.io/${github_repository.testing.full_name}/infra-live:latest")
  vpc_endpoints = toset([
    "com.amazonaws.${data.aws_region.current.name}.ecr.dkr",
    "com.amazonaws.${data.aws_region.current.name}.ecr.api",
    "com.amazonaws.${data.aws_region.current.name}.s3"
  ])
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

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
  name        = "${local.mut_id}-tf-state-read-access"
  path        = "/"
  description = "Allows ECS tasks to read from terraform state S3 bucket"
  policy      = data.aws_iam_policy_document.trigger_sf_tf_state_access.json
}

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "1.3.2"

  repository_name = local.mut_id
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 5 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 5
        },
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# build docker image used for ECS tasks
# needed for testing current implementation of docker image or else
# the module will use the pre-existing master's branch latest version
resource "null_resource" "build" {
  triggers = { for file in local.trigger_file_paths : basename(file) => filesha256(file) }

  provisioner "local-exec" {
    command     = <<EOF
#!/bin/bash

set -e

docker build -t ${local.full_image_url} ${local.docker_context}
echo ${var.registry_password} | docker login ghcr.io -u ${var.registry_username} --password-stdin
docker push ${local.full_image_url}
EOF
    interpreter = ["bash", "-c"]
  }
}

# test VPC used for hosting ECS tasks
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.14.2"

  name = local.mut_id
  cidr = "10.0.0.0/16"

  azs            = ["${data.aws_region.current.name}a", "${data.aws_region.current.name}b"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  create_igw           = true
  enable_dns_hostnames = true
  enable_dns_support   = true
}

module "mut_infrastructure_live_ci" {
  source = "../../..//"

  prefix = local.mut_id

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

  metadb_username    = "mut_user"
  metadb_password    = random_password.metadb["master"].result
  metadb_ci_username = "mut_ci_user"
  metadb_ci_password = random_password.metadb["ci"].result
  metadb_schema      = var.metadb_schema
  metadb_subnet_ids  = module.vpc.public_subnets

  vpc_id               = module.vpc.vpc_id
  ecs_subnet_ids       = module.vpc.public_subnets
  ecs_assign_public_ip = true

  private_registry_auth          = true
  create_private_registry_secret = true
  registry_username              = var.registry_username
  registry_password              = var.registry_password
  ecs_image_address              = local.full_image_url

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
    github_repository.testing,
    null_resource.build
  ]
}