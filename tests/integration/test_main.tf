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
  auto_init   = true
  visibility  = "public"
  template {
    owner      = "marshall7m"
    repository = "infrastructure-live-testing-template"
  }
}

data "aws_ssm_parameter" "metadb_password" {
  name = "metadb-password"
}

data "aws_caller_identity" "current" {}


module "mut_infrastructure_live_ci" {
  source = "../..//"

  plan_role_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  apply_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]

  repo_name   = github_repository.test.name
  base_branch = "master"

  metadb_publicly_accessible = true
  metadb_username            = "mut_user"
  metadb_password            = data.aws_ssm_parameter.metadb_password.value

  create_github_token_ssm_param = false
  github_token_ssm_key          = "admin-github-token"

  approval_request_sender_email = "success@simulator.amazonses.com"
  #incorporate other account for testing (e.g. prod)
  account_parent_cfg = [
    {
      name         = "dev"
      path         = "dev-account"
      dependencies = []
      voters       = ["success@simulator.amazonses.com"]
      # voters                   = [data.aws_ssm_parameter.testing_email.value]
      approval_count_required  = 1
      rejection_count_required = 1
    }
  ]

  depends_on = [
    github_repository.test
  ]
}

module "bats_testing" {
  source        = "github.com/marshall7m/terraform-bats-testing//"
  bats_filepath = "${path.module}/test_integration.bats"
  env_vars = {
    PGUSER     = module.mut_infrastructure_live_ci.metadb_username
    PGPASSWORD = module.mut_infrastructure_live_ci.metadb_password
    PGHOST     = module.mut_infrastructure_live_ci.metadb_address
    PGDATABASE = module.mut_infrastructure_live_ci.metadb_name

    TRIGGER_SF_CODEBUILD_ARN = module.mut_infrastructure_live_ci.codebuild_trigger_sf_arn
  }
  depends_on = [
    module.mut_infrastructure_live_ci
  ]
}