data "aws_region" "current" {}

resource "random_password" "metadb" {
  for_each = toset(["master", "ci"])
  length   = 16
  special  = false
}

resource "random_string" "mut" {
  length  = 8
  lower   = true
  upper   = false
  special = false
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