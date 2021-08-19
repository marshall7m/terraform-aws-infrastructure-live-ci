resource "github_branch" "test_one_dep" {
  repository    = github_repository.test.name
  source_branch = "master"
  branch        = "test-one-dep"
}

resource "github_repository_pull_request" "test_one_dep" {
  base_repository = github_repository.test.name
  base_ref        = "master"
  head_ref        = github_branch.test_one_dep.branch
  title           = "overite baz"
  body            = "Test mut: ${local.mut} ability to handle the modified configurations with one dependency (dev-account/baz)"
  depends_on = [
    github_repository_file.test_one_dep
  ]
}

resource "github_repository_file" "test_one_dep" {
  repository          = github_repository.test.name
  branch              = github_branch.test_one_dep.branch
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