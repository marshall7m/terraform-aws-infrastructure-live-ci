locals {
  mut_id = "mut-terraform-aws-infrastructure-live-ci-${random_string.this.result}"
}

resource "random_string" "this" {
  length      = 10
  min_numeric = 5
  special     = false
  lower       = true
  upper       = false
}

resource "github_repository" "test" {
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
  acl    = "private"

  versioning {
    enabled = true
  }
  server_side_encryption_configuration {
    rule {
      bucket_key_enabled = true
      apply_server_side_encryption_by_default {
        sse_algorithm = "aws:kms"
      }
    }
  }
}

data "aws_kms_key" "s3" {
  key_id = "alias/aws/s3"
}

data "aws_iam_policy_document" "testing_tf_state_kms" {
  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt"
    ]
    resources = [data.aws_kms_key.s3.arn]
  }
}

resource "aws_iam_policy" "codebuild_tf_state_access" {
  name        = "${aws_s3_bucket.testing_tf_state.id}-kms-access"
  description = "Allows Codebuild services to encrypt/decrypt objects from tf-state bucket"
  policy      = data.aws_iam_policy_document.testing_tf_state_kms.json
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
    sid       = "DenyUnEncryptedObjectUploads"
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
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyInsecureConnections"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["${aws_s3_bucket.testing_tf_state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
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

module "mut_infrastructure_live_ci" {
  source = "../.."

  #scope of tests are within one AWS account so AWS managed policies within target account are used
  # for multi-account setup use var.(plan|apply)_role_assumable_role_arns to cross-account roles codebuild can assume
  plan_role_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  apply_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]

  repo_full_name = github_repository.test.full_name
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

  codebuild_common_policy_arns = [aws_iam_policy.codebuild_tf_state_access.arn]

  create_github_token_ssm_param = false
  github_token_ssm_key          = "admin-github-token"

  approval_request_sender_email = "success@simulator.amazonses.com"
  account_parent_cfg = [
    {
      name                = "dev"
      path                = "directory_dependency/dev-account"
      dependencies        = []
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
    }
  ]

  depends_on = [
    github_repository.test
  ]
}