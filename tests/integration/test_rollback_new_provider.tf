resource "github_branch" "test_rollback_new_provider" {
  repository    = github_repository.test.name
  source_branch = "master"
  branch        = "test-rollback-new-provider"
}

resource "github_repository_pull_request" "test_rollback_new_provider" {
  base_repository = github_repository.test.name
  base_ref        = "master"
  head_ref        = github_branch.test_rollback_new_provider.branch
  title           = "overite baz"
  body            = "Test mut: ${local.mut} ability to rollback new providers and revert cfg to base ref"
  depends_on = [
    github_repository_file.test_rollback_new_provider
  ]
}

resource "github_repository_file" "test_rollback_new_provider" {
  repository          = github_repository.test.name
  branch              = github_branch.test_rollback_new_provider.branch
  file                = "dev-account/baz/ssm.tf"
  content             = <<EOF
resource "aws_ssm_parameter" "test" {
  name  = "mut-terraform-aws-infrastructure-live-ci"
  type  = "String"
  value = "baz"
}

output "ssm_param" {
  value = aws_ssm_parameter.test.value
}
EOF
  commit_message      = "add aws provider & ssm param resource"
  overwrite_on_create = true
  depends_on = [
    module.mut_infrastructure_live_ci
  ]
}