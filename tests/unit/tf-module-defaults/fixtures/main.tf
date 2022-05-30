resource "github_repository" "testing" {
  name        = "mut_infrastructure_live_ci_testing_plan"
  description = "Test repo for mut: terraform-aws-infrastructure-live-ci"
  visibility  = "public"
}

module "mut_infrastructure_live_ci" {
  source = "../../../..//"

  approval_request_sender_email = "success@simulator.amazonses.com"
  repo_name                     = github_repository.testing.name
  account_parent_cfg = [
    {
      name                = "test"
      path                = "test"
      dependencies        = []
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::123456789101:role/tf-plan"
      deploy_role_arn     = "arn:aws:iam::123456789101:role/tf-apply"
    }
  ]
  metadb_ci_password          = "test-ci"
  metadb_password             = "test"
  tf_state_read_access_policy = "arn:aws:iam::123456789101:role/tf-apply"
}