module "terra_img" {
  count  = var.terra_img == null ? 1 : 0
  source = "github.com/marshall7m/terraform-aws-ecr/modules//ecr-docker-img"

  create_repo         = true
  codebuild_access    = true
  source_path         = "${path.module}/modules/testing-img"
  repo_name           = "infrastructure-live-ci"
  tag                 = "latest"
  trigger_build_paths = ["${path.module}/modules/testing-img"]
}

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

module "codebuild_terra_run" {
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
      },
      {
        name  = "SECONDARY_SOURCE_IDENTIFIER"
        type  = "PLAINTEXT"
        value = local.buildspec_scripts_source_identifier
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

  secondary_build_source = {
    source_identifier = local.buildspec_scripts_source_identifier
    type              = "S3"
    location          = "${aws_s3_bucket.artifacts.id}/${local.buildspec_scripts_key}"
  }

  role_policy_arns = [aws_iam_policy.artifact_bucket_access.arn]

  depends_on = [
    aws_s3_bucket_object.build_scripts
  ]
}

module "codebuild_queue_pr" {
  source = "github.com/marshall7m/terraform-aws-codebuild"


  webhook_filter_groups = [
    [
      {
        pattern = "PULL_REQUEST_CREATED,PULL_REQUEST_UPDATED,PULL_REQUEST_REOPENED"
        type    = "EVENT"
      },
      {
        pattern = var.base_branch
        type    = "BASE_REF"
      },
      {
        pattern = var.file_path_pattern
        type    = "FILE_PATH"
      }
    ]
  ]

  create_source_auth         = true
  source_auth_ssm_param_name = var.github_token_ssm_key
  source_auth_type           = "PERSONAL_ACCESS_TOKEN"
  source_auth_server_type    = "GITHUB"

  name = var.queue_pr_build_name
  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_queue.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = true
  }

  secondary_build_source = {
    source_identifier = local.buildspec_scripts_source_identifier
    type              = "S3"
    location          = "${aws_s3_bucket.artifacts.id}/${local.buildspec_scripts_key}"
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:3.0"
    type         = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "ARTIFACT_BUCKET_NAME"
        type  = "PLAINTEXT"
        value = aws_s3_bucket.artifacts.id
      },
      {
        name  = "ARTIFACT_BUCKET_PR_QUEUE_KEY"
        type  = "PLAINTEXT"
        value = local.pr_queue_key
      },
      {
        name  = "SECONDARY_SOURCE_IDENTIFIER"
        type  = "PLAINTEXT"
        value = local.buildspec_scripts_source_identifier
      }
    ]
  }

  role_policy_arns = [aws_iam_policy.artifact_bucket_access.arn]

  depends_on = [
    aws_s3_bucket_object.build_scripts
  ]
}

module "codebuild_trigger_sf" {
  source = "github.com/marshall7m/terraform-aws-codebuild"

  name = var.trigger_step_function_build_name

  source_auth_token          = var.github_token_ssm_value
  source_auth_server_type    = "GITHUB"
  source_auth_type           = "PERSONAL_ACCESS_TOKEN"
  source_auth_ssm_param_name = var.github_token_ssm_key

  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_trigger_sf.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
  }

  secondary_build_source = {
    source_identifier = local.buildspec_scripts_source_identifier
    type              = "S3"
    location          = "${aws_s3_bucket.artifacts.id}/${local.buildspec_scripts_key}"
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }

  environment = {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = coalesce(var.terra_img, module.terra_img[0].full_image_url)
    image_pull_credentials_type = "SERVICE_ROLE"
    type                        = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "BUILD_NAME"
        value = var.trigger_step_function_build_name
        type  = "PLAINTEXT"
      },
      {
        name  = "STATE_MACHINE_ARN"
        value = aws_sfn_state_machine.this.arn
        type  = "PLAINTEXT"
      },
      {
        name  = "ARTIFACT_BUCKET_NAME"
        type  = "PLAINTEXT"
        value = aws_s3_bucket.artifacts.id
      },
      {
        name  = "SECONDARY_SOURCE_IDENTIFIER"
        type  = "PLAINTEXT"
        value = local.buildspec_scripts_source_identifier
      },
      {
        name  = "EVENTBRIDGE_RULE"
        type  = "PLAINTEXT"
        value = aws_cloudwatch_event_rule.this.id
      },
      {
        name  = "ROLLOUT_PLAN_COMMAND"
        type  = "PLAINTEXT"
        value = var.rollout_plan_command
      },
      {
        name  = "ROLLOUT_DEPLOY_COMMAND"
        type  = "PLAINTEXT"
        value = var.rollout_deploy_command
      },
      {
        name  = "ROLLBACK_PLAN_COMMAND"
        type  = "PLAINTEXT"
        value = var.rollback_plan_command
      },
      {
        name  = "ROLLBACK_DEPLOY_COMMAND"
        type  = "PLAINTEXT"
        value = var.rollback_deploy_command
      }
    ]
  }
  role_policy_arns = [aws_iam_policy.artifact_bucket_access.arn]

  role_policy_statements = [
    {
      sid       = "StepFunctionTriggerAccess"
      effect    = "Allow"
      actions   = ["states:StartExecution"]
      resources = [aws_sfn_state_machine.this.arn]
    }
  ]

  depends_on = [
    aws_s3_bucket_object.build_scripts
  ]

}

data "github_repository" "this" {
  name = var.repo_name
}

data "aws_caller_identity" "current" {}