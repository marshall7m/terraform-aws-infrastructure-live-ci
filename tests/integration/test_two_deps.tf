resource "github_branch" "test_two_deps" {
  repository    = github_repository.test.name
  source_branch = "master"
  branch        = "test-two-deps"
}

resource "github_repository_pull_request" "test_two_deps" {
  base_repository = github_repository.test.name
  base_ref        = "master"
  head_ref        = github_branch.test_two_deps.branch
  title           = "overite baz"
  body            = "Test mut: ${local.mut} ability to handle the modified configurations with one dependency (dev-account/baz)"
  depends_on = [
    github_repository_file.test_two_deps
  ]
}

resource "github_repository_file" "test_two_deps" {
  repository          = github_repository.test.name
  branch              = github_branch.test_two_deps.branch
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