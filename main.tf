resource "aws_codestarconnections_connection" "github" {
  name          = coalesce(var.codestar_name, substr(var.pipeline_name, 0, 32))
  provider_type = "GitHub"
}

module "codebuild" {
  count               = var.enabled ? 1 : 0
  source              = "github.com/marshall7m/terraform-aws-codebuild"
  name                = var.build_name
  assumable_role_arns = var.build_assumable_role_arns
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
  count      = var.enabled ? 1 : 0
  source     = "github.com/marshall7m/terraform-aws-codepipeline"
  account_id = var.account_id
  name       = var.pipeline_name
  cmk_arn    = var.cmk_arn
  # create placeholder stages since codepipeline requires two actions
  # stages/actions are updated via Step Function
  stages = [
    {
      name = "${var.repo_id}"
      actions = [
        {
          name             = "source"
          category         = "Source"
          owner            = "AWS"
          version          = 1
          provider         = "CodeStarSourceConnection"
          output_artifacts = [var.branch]
          configuration = {
            ConnectionArn    = aws_codestarconnections_connection.github.arn
            FullRepositoryId = var.repo_id
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