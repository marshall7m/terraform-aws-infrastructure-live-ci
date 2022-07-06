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

provider "aws" {
  alias = "secondary"
  assume_role {
    role_arn     = "arn:aws:iam::${var.testing_secondary_aws_account_id}:role/cross-account-admin-access"
    session_name = "${local.mut_id}-testing"
  }
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

module "secondary_plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name = local.plan_role_name
  trusted_entities = [
    module.mut_infrastructure_live_ci.ecs_create_deploy_stack_role_arn,
    module.mut_infrastructure_live_ci.ecs_plan_role_arn
  ]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  providers = {
    aws = aws.secondary
  }
}

module "secondary_deploy_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name               = local.deploy_role_name
  trusted_entities        = [module.mut_infrastructure_live_ci.ecs_apply_role_arn]
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

  azs             = ["${data.aws_region.current.name}a", "${data.aws_region.current.name}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  private_dedicated_network_acl = true
  # for some odd reason opening up all inbound fixes the ECS networking issue for pulling the image
  # TODO: fix once solution is present SO post: https://stackoverflow.com/questions/72780753/aws-ecs-resourceinitializationerror-unable-to-pull-secrets-or-registry-auth
  private_inbound_acl_rules = [
    {
      cidr_block  = "0.0.0.0/0"
      from_port   = 0,
      protocol    = "-1",
      rule_action = "allow",
      rule_number = 1,
      to_port     = 0
    }
  ]
  private_outbound_acl_rules = [
    {
      cidr_block  = "0.0.0.0/0"
      from_port   = 443,
      protocol    = "tcp",
      rule_action = "allow",
      rule_number = 1,
      to_port     = 443
    },
    {
      cidr_block  = "0.0.0.0/0"
      from_port   = 80,
      protocol    = "tcp",
      rule_action = "allow",
      rule_number = 2,
      to_port     = 80
    },
    {
      cidr_block  = "0.0.0.0/0"
      from_port   = 53,
      protocol    = "tcp",
      rule_action = "allow",
      rule_number = 3,
      to_port     = 53
    },
    {
      cidr_block  = "0.0.0.0/0"
      from_port   = 53,
      protocol    = "udp",
      rule_action = "allow",
      rule_number = 4,
      to_port     = 53
    }
  ]
}

resource "aws_security_group" "ecs_tasks" {
  name   = "Allow access to ECR-related VPC endpoints"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name   = "Allow access to ECS tasks"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    # security_groups = [aws_security_group.ecs_tasks.id]
  }
}

resource "aws_vpc_endpoint" "ecr" {
  for_each           = local.vpc_endpoints
  vpc_id             = module.vpc.vpc_id
  service_name       = each.value
  vpc_endpoint_type  = "Interface"
  security_group_ids = [aws_security_group.vpc_endpoints.id]
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
  # can be used for integration testing assertions
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
    Deploy            = true
    Execution         = true
  }

  metadb_username    = "mut_user"
  metadb_password    = random_password.metadb["master"].result
  metadb_ci_username = "mut_ci_user"
  metadb_ci_password = random_password.metadb["ci"].result
  metadb_schema      = var.metadb_schema

  ecs_vpc_id             = module.vpc.vpc_id
  ecs_private_subnet_ids = module.vpc.private_subnets

  private_registry_auth          = true
  create_private_registry_secret = true
  registry_username              = var.registry_username
  registry_password              = var.registry_password
  ecs_image_address              = local.full_image_url
  ecs_security_group_ids         = [aws_security_group.ecs_tasks.id]

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
    github_repository.testing,
    null_resource.build
  ]
}