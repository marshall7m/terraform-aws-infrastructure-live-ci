locals {
  mut    = "infrastructure-ci"
  mut_id = "mut-${local.mut}-${random_id.default.id}"
}

resource "random_id" "default" {
  byte_length = 8
}

resource "github_repository" "test" {
  name        = "mut-${local.mut}"
  description = "Test repo for mut: ${local.mut}"
  auto_init   = true
  visibility  = "public"
  template {
    owner      = "marshall7m"
    repository = "infrastructure-live-testing-template"
  }
}

data "aws_ssm_parameter" "testing_email" {
  name = "testing-email"
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

  metadb_username = "${local.mut_id}-user"
  metadb_password = data.aws_ssm_parameter.metadb_password.value

  create_github_token_ssm_param = false
  github_token_ssm_key          = "github-webhook-request-validator-github-token"

  approval_request_sender_email = data.aws_ssm_parameter.testing_email.value
  #incorporate other account for testing (e.g. prod)
  account_parent_cfg = [
    {
      name                     = "dev"
      path                     = "dev-account"
      dependencies             = []
      voters                   = [data.aws_ssm_parameter.testing_email.value]
      approval_count_required  = 1
      rejection_count_required = 1
    }
  ]

  depends_on = [
    github_repository.test
  ]
}