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