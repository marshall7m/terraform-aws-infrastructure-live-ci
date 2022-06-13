resource "random_string" "mut" {
  length  = 8
  lower   = true
  upper   = false
  special = false
}

module "mut_infrastructure_live_ci" {
  source                        = "../../../..//"
  prefix                        = "mut-${random_string.mut.id}"
  approval_request_sender_email = "success@simulator.amazonses.com"
  send_verification_email       = false

  create_merge_lock_github_token_ssm_param = true
  repo_name                                = var.repo_name
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