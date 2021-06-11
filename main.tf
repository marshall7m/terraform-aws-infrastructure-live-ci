resource "aws_codestarconnections_connection" "github" {
  name          = coalesce(var.codestar_name, substr(var.pipeline_name, 0, 32))
  provider_type = "GitHub"
}

module "plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = coalesce(var.plan_role_name, "${var.pipeline_name}-tf-plan-action")
  trusted_entities        = ["codebuild.amazonaws.com"]
  custom_role_policy_arns = var.plan_role_policy_arns
  statements = [
    {
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.plan_role_assumable_role_arns
    }
  ]
}

module "apply_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = coalesce(var.apply_role_name, "${var.pipeline_name}-tf-apply-action")
  trusted_entities        = ["codebuild.amazonaws.com"]
  custom_role_policy_arns = var.apply_role_policy_arns
  statements = [
    {
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.apply_role_assumable_role_arns
    }
  ]
}

module "codebuild" {
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
    type = "CODEPIPELINE"
  }
  build_source = {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspec.yaml")
  }
}

module "codepipeline" {
  source     = "github.com/marshall7m/terraform-aws-codepipeline"
  account_id = var.account_id
  name       = var.pipeline_name
  cmk_arn    = var.cmk_arn
  # create placeholder stages since codepipeline requires two actions
  # stages/actions are updated via Step Function
  stages = [
    {
      name = data.github_repository.this.repo_id
      actions = [
        {
          name             = "source"
          category         = "Source"
          owner            = "AWS"
          provider         = "CodeStarSourceConnection"
          version          = 1
          output_artifacts = [var.branch]
          configuration = {
            ConnectionArn = aws_codestarconnections_connection.github.arn
            #retrieve full name of repo via data src given var.repos is used in for_each within `module.github_webhook`
            FullRepositoryId = data.github_repository.this.repo_id
            BranchName       = var.branch
          }
        }
      ]
    },
    {
      name = "placeholder"
      actions = [
        {
          name     = "approval"
          category = "Approval"
          owner    = "AWS"
          provider = "Manual"
          version  = 1
        }
      ]
    }
  ]
}

data "github_repository" "this" {
  name = var.repo_name
}