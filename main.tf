resource "random_integer" "artifact_bucket" {
  count = var.enabled ? 1 : 0
  min   = 10000000
  max   = 99999999
  seed  = 1
}

resource "aws_codestarconnections_connection" "github" {
  name          = var.pipeline_name
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
  count                = var.enabled ? 1 : 0
  source               = "github.com/marshall7m/terraform-aws-codepipeline"
  account_id           = var.account_id
  name                 = var.pipeline_name
  cmk_arn              = var.cmk_arn
  artifact_bucket_name = coalesce(var.artifact_bucket_name, "${var.pipeline_name}-${random_integer.artifact_bucket[0].result}")
  stages = concat([
    {
      name = "1-${split("/", var.repo_id)[1]}"
      actions = [
        {
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
    }
    ],
    [for stage in var.stages : {
      name = "${stage.order == 1 ? stage.order + 1 : stage.order}-${stage.name}"
      actions = [
        {
          category         = "Test"
          owner            = "AWS"
          provider         = "CodeBuild"
          version          = 1
          input_artifacts  = [var.branch]
          output_artifacts = ["${stage.name}-testing"]
          role_arn         = stage.tf_plan_role_arn
          configuration = {
            ProjectName = var.build_name
            EnvironmentVariables = [
              {
                name  = "COMMAND"
                value = "terragrunt run-all apply -auto-approve"
                type  = "PLAINTEXT"
              },
              {
                name  = "PATH"
                value = stage.paths
                type  = "PLAINTEXT"
              }
            ]
          }
          run_order = 1
        },
        {
          category  = "Approval"
          owner     = "AWS"
          provider  = "Manual"
          version   = 1
          run_order = 2
        },
        {
          category         = "Build"
          owner            = "AWS"
          provider         = "CodeBuild"
          version          = 1
          input_artifacts  = [var.branch]
          output_artifacts = ["${stage.name}-apply"]
          role_arn         = stage.tf_apply_role_arn
          configuration = {
            ProjectName = var.build_name
            EnvironmentVariables = [
              {
                name  = "COMMAND"
                value = "terragrunt run-all apply -auto-approve"
                type  = "PLAINTEXT"
              },
              {
                name  = "PATH"
                value = stage.paths
                type  = "PLAINTEXT"
              }
            ]
          }
          run_order = 3
        }
      ]
      }
  ])
}