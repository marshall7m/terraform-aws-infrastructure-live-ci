locals {
  mut_id           = "mut-terraform-aws-infrastructure-live-ci-${random_string.this.result}"
  plan_role_name   = "${local.mut_id}-plan"
  deploy_role_name = "${local.mut_id}-deploy"
  approval_key     = "approval"
  voters           = [data.aws_ssm_parameter.testing_sender_email.value]
}

data "aws_caller_identity" "current" {}

resource "random_string" "this" {
  length      = 10
  min_numeric = 5
  special     = false
  lower       = true
  upper       = false
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

resource "aws_s3_bucket_acl" "testing_tf_state" {
  bucket = aws_s3_bucket.testing_tf_state.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "testing_tf_state" {
  bucket = aws_s3_bucket.testing_tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "testing_tf_state" {
  bucket = aws_s3_bucket.testing_tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "testing_tf_state" {
  statement {
    sid       = "DenyIncorrectEncryptionHeader"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.testing_tf_state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }

  statement {
    sid       = "DenyUnencryptedObjectUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.testing_tf_state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["true"]
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

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name                 = local.mut_id
  cidr                 = "10.0.0.0/16"
  azs                  = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
  enable_dns_hostnames = true
  private_subnets      = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets       = ["10.0.21.0/24", "10.0.22.0/24"]
  database_subnets     = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
}

module "plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name = local.plan_role_name
  trusted_entities = [
    module.mut_infrastructure_live_ci.codebuild_trigger_sf_role_arn,
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

module "testing_ses_approval_bucket" {
  source     = "../modules/ses_approval"
  bucket_id  = "${local.mut_id}-approval"
  rule_name  = "${local.mut_id}-approval"
  key        = local.approval_key
  recipients = local.voters
}

module "mut_infrastructure_live_ci" {
  source = "../.."

  repo_full_name = github_repository.testing.full_name
  base_branch    = "master"

  metadb_publicly_accessible = true
  metadb_username            = "mut_user"
  metadb_password            = random_password.metadb["master"].result

  metadb_ci_username          = "mut_ci_user"
  metadb_ci_password          = random_password.metadb["ci"].result
  enable_metadb_http_endpoint = true

  metadb_subnets_group_name = module.vpc.database_subnet_group_name

  codebuild_vpc_config = {
    vpc_id  = module.vpc.vpc_id
    subnets = module.vpc.private_subnets
  }

  lambda_subnet_ids = module.vpc.private_subnets

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
      dependencies        = []
      voters              = local.voters
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.plan_role_name}"
      deploy_role_arn     = "arn:aws:iam::${data.aws_caller_identity.current.id}:role/${local.deploy_role_name}"
    }
  ]

  depends_on = [
    github_repository.testing
  ]
}

data "aws_ssm_parameter" "testing_sender_email" {
  name = "testing-ses-email-address"
}