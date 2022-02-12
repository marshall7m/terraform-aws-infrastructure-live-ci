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

  create_github_token_ssm_param = false
  github_token_ssm_key          = "admin-github-token"

  approval_request_sender_email = "success@simulator.amazonses.com"
  account_parent_cfg = [
    {
      name                     = "dev"
      path                     = "dev-account"
      dependencies             = []
      voters                   = ["success@simulator.amazonses.com"]
      approval_count_required  = 1
      rejection_count_required = 1
    }
  ]

  depends_on = [
    github_repository.test
  ]
}