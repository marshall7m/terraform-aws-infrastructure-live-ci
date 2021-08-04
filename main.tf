module "plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = var.plan_role_name
  trusted_services        = ["codebuild.amazonaws.com"]
  custom_role_policy_arns = var.plan_role_policy_arns
  statements = length(var.plan_role_assumable_role_arns) > 0 ? [
    {
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.plan_role_assumable_role_arns
    }
  ] : []
}

module "apply_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = var.apply_role_name
  trusted_services        = ["codebuild.amazonaws.com"]
  custom_role_policy_arns = var.apply_role_policy_arns
  statements = length(var.apply_role_assumable_role_arns) > 0 ? [
    {
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.apply_role_assumable_role_arns
    }
  ] : []
}

module "codebuild_terraform_deploy" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = var.build_name
  assumable_role_arns = [
    module.plan_role.role_arn,
    module.apply_role.role_arn
  ]
  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:3.0"
    type         = "LINUX_CONTAINER"
    environment_variables = concat(var.build_env_vars, [
      {
        name  = "TF_IN_AUTOMATION"
        value = "true"
        type  = "PLAINTEXT"
      },
      {
        name  = "TF_INPUT"
        value = "false"
        type  = "PLAINTEXT"
      }
    ])
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }
  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_ci.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
  }

  role_policy_arns = [aws_iam_policy.artifact_bucket_access.arn]

}

data "github_repository" "this" {
  name = var.repo_name
}

module "codebuild_rollback_provider" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = var.get_rollback_providers_build_name
  assumable_role_arns = [
    module.plan_role.role_arn
  ]
  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:3.0"
    type         = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "TERRAGRUNT_WORKING_DIR"
        type  = "PLAINTEXT"
        value = var.terragrunt_parent_dir
      }
    ]
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }
  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_rollback_new_provider.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
  }
}

data "aws_caller_identity" "current" {}