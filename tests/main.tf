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

resource "github_branch" "test_no_deps" {
  repository    = github_repository.test.name
  source_branch = "master"
  branch        = "test-no-deps"
}

resource "github_repository_pull_request" "test_no_deps" {
  base_repository = github_repository.test.name
  base_ref        = "master"
  head_ref        = github_branch.test_no_deps.branch
  title           = "overite baz"
  body            = "Test mut: ${local.mut} ability to handle the modified configurations with no dependencies"
  depends_on = [
    github_repository_file.test_no_deps
  ]
}

resource "github_repository_file" "test_no_deps" {
  repository          = github_repository.test.name
  branch              = github_branch.test_no_deps.branch
  file                = "dev-account/baz/terragrunt.hcl"
  content             = <<EOF
terraform {
    source = ".//"
}

inputs = {
    value = "overwrite_baz"
}
EOF
  commit_message      = "overwrite baz"
  overwrite_on_create = true
  depends_on = [
    module.mut_infrastructure_live_ci
  ]
}

resource "github_repository_file" "test_bar" {
  repository          = github_repository.test.name
  branch              = "master"
  file                = "dev-account/bar/terragrunt.hcl"
  content             = <<EOF
terraform {
    source = ".//"
}

dependency "baz" {
    config_path = "../baz"
}

inputs = {
    dependency = "overwrite_bar"
}
EOF
  commit_message      = "overwrite bar"
  overwrite_on_create = true
  depends_on = [
    module.mut_infrastructure_live_ci
  ]
}

resource "github_repository_file" "test_foo" {
  repository          = github_repository.test.name
  branch              = "master"
  file                = "dev-account/foo/terragrunt.hcl"
  content             = <<EOF
terraform {
    source = ".//"
}

dependency "bar" {
    config_path = "../bar"
}

inputs = {
    dependency = "overwrite_foo"
}
EOF
  commit_message      = "overwrite foo"
  overwrite_on_create = true
  depends_on = [
    module.mut_infrastructure_live_ci
  ]
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

  stage_parent_paths = ["dev-account"]

  depends_on = [
    github_repository.test
  ]
}