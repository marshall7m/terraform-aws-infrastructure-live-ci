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
}

resource "null_resource" "setup_repo" {
  triggers = {
    run = github_repository.test.http_clone_url
  }
  provisioner "local-exec" {
    command = templatefile("setup_repo.sh", {
      clone_url = github_repository.test.http_clone_url
    })
  }
}

resource "github_repository_file" "test_baz" {
  repository          = github_repository.test.name
  branch              = "master"
  file                = "baz/terragrunt.hcl"
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
  file                = "bar/terragrunt.hcl"
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
  file                = "foo/terragrunt.hcl"
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
  source        = "..//"
  account_id    = data.aws_caller_identity.current.id
  pipeline_name = local.mut_id

  plan_cmd  = "terragrunt plan"
  apply_cmd = "terragrunt apply -auto-approve"

  plan_role_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  apply_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]

  repo_name = github_repository.test.name
  branch    = "master"

  create_github_token_ssm_param = false
  github_token_ssm_key          = "github-webhook-request-validator-github-token"

  stage_parent_paths = [
    "baz",
    "foo"
  ]
  repo_filter_groups = [
    {
      events = ["pull_request"]
    }
  ]
  depends_on = [
    github_repository.test
  ]
}