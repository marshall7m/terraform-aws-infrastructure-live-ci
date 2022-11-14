provider "docker" {
  # sets up ECR registry authorization so mut can push to ECR
  dynamic "registry_auth" {
    for_each = var.is_remote ? [1] : []
    content {
      address  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
      password = data.aws_ecr_authorization_token.token[0].password
      username = data.aws_ecr_authorization_token.token[0].user_name
    }
  }
}