module "mut_infrastructure_live_ci" {
  source = "../../../../../../../..//"

  prefix                        = "mut-defaults"
  approval_request_sender_email = "success@simulator.amazonses.com"
  send_verification_email       = true
  create_github_token_ssm_param = true
  repo_clone_url                = "https://host.xz/path/to/repo.git"
  account_parent_cfg = [
    {
      name                = "test"
      path                = "test"
      dependencies        = []
      voters              = ["success@simulator.amazonses.com"]
      min_approval_count  = 1
      min_rejection_count = 1
      plan_role_arn       = "arn:aws:iam::123456789101:role/tf-plan"
      apply_role_arn      = "arn:aws:iam::123456789101:role/tf-apply"
    }
  ]
  metadb_ci_password          = "test-ci"
  metadb_password             = "test"
  tf_state_read_access_policy = "arn:aws:iam::123456789101:role/tf-apply"
  vpc_id                      = "vpc-123"
  metadb_subnet_ids           = ["subnet-123"]
  ecs_subnet_ids              = ["subnet-123"]
}