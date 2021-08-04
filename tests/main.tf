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

data "aws_caller_identity" "current" {}

module "mut_infrastructure_live_ci" {
  source     = "..//"
  account_id = data.aws_caller_identity.current.id

  plan_role_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  apply_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]

  repo_name   = github_repository.test.name
  base_branch = "master"

  create_github_token_ssm_param = false
  github_token_ssm_key          = "github-webhook-request-validator-github-token"

  approval_request_sender_email = data.aws_ssm_parameter.testing_email.value
  account_parent_cfg = [
    {
      name                     = "dev"
      paths                    = ["dev/"]
      voters                   = [data.aws_ssm_parameter.testing_email.value]
      approval_count_required  = 2
      rejection_count_required = 2
    },
    {
      name                     = "prod"
      paths                    = ["prod/"]
      voters                   = [data.aws_ssm_parameter.testing_email.value]
      approval_count_required  = 2
      rejection_count_required = 2
    }
  ]

  depends_on = [
    github_repository.test
  ]
}