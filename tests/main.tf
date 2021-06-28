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

  plan_cmd  = "terragrunt plan"
  apply_cmd = "terragrunt apply -auto-approve"

  plan_role_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  apply_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]

  repo_name   = github_repository.test.name
  base_branch = "master"

  create_github_token_ssm_param = false
  github_token_ssm_key          = "github-webhook-request-validator-github-token"

  account_parent_paths = ["dev-account"]

  approval_emails = [data.aws_ssm_parameter.testing_email.value]
  depends_on = [
    github_repository.test
  ]
}

module "test_simpledb_queue" {
  source           = "digitickets/cli/aws"
  version          = "4.0.0"
  aws_cli_commands = ["sdb", "select", "--select-expression", "'SELECT * FROM `${module.mut_infrastructure_live_ci.queue_db_name}`'"]

  depends_on = [
    module.mut_infrastructure_live_ci,
    github_repository_file.test_no_deps,
    github_repository_file.test_one_dep,
    github_repository_file.test_two_deps
  ]
}

output "test" {
  value = module.test_simpledb_queue.result
}

output "definition" {
  value = jsondecode(module.mut_infrastructure_live_ci.definition)
}