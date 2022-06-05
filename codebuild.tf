locals {
  terraform_module_version = trimspace(file("${path.module}/source_version.txt"))
  merge_lock_name          = coalesce(var.merge_lock_build_name, "${var.prefix}-merge-lock")

  pr_plan_build_name                  = coalesce(var.pr_plan_build_name, "${var.prefix}-pr-plan")
  create_deploy_stack_build_name      = coalesce(var.create_deploy_stack_build_name, "${var.prefix}-create-deploy-stack")
  terra_run_build_name                = coalesce(var.terra_run_build_name, "${var.prefix}-terra-run")
  buildspec_scripts_source_identifier = "helpers"

  build_img = coalesce(
    var.build_img,
    "ghcr.io/${data.github_repository.build_scripts.full_name}:${local.terraform_module_version == "master" ? "latest" : local.terraform_module_version}"
  )
}

data "github_repository" "build_scripts" {
  # for testing this module with your fork of the repo, change `full_name` to your fork's full name
  full_name = "marshall7m/terraform-aws-infrastructure-live-ci"
}

data "github_repository" "this" {
  name = var.repo_name
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_ssm_parameter" "merge_lock" {
  name        = local.merge_lock_name
  description = "Locks PRs with infrastructure changes from being merged into base branch"
  type        = "String"
  value       = "none"
}

resource "aws_ssm_parameter" "metadb_ci_password" {
  name        = "${local.metadb_name}_${var.metadb_ci_username}"
  description = "Metadb password used by module's Codebuild projects"
  type        = "SecureString"
  value       = var.metadb_ci_password
}

module "codebuild_create_deploy_stack" {
  source = "github.com/marshall7m/terraform-aws-codebuild"

  name                    = local.create_deploy_stack_build_name
  create_source_auth      = var.codebuild_source_auth_token != null ? true : false
  source_auth_token       = var.codebuild_source_auth_token
  source_auth_server_type = "GITHUB"
  source_auth_type        = "PERSONAL_ACCESS_TOKEN"
  build_source = {
    type                = "GITHUB"
    git_clone_depth     = 0
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = true
    build_status_config = {
      context = var.create_deploy_stack_status_check_name
    }
    buildspec = <<-EOT
version: 0.2
env:
  shell: bash
phases:
  install:
    commands:
      - bash "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}/buildspecs/img/entrypoint.sh"
      - pip install -e "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}"
  build:
    commands:
      - python "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}/buildspecs/create_deploy_stack/create_deploy_stack.py"
EOT
  }

  secondary_build_source = {
    source_identifier   = local.buildspec_scripts_source_identifier
    type                = "GITHUB"
    git_clone_depth     = 1
    report_build_status = false
    insecure_ssl        = false
    location            = data.github_repository.build_scripts.http_clone_url
    source_version      = local.terraform_module_version
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = local.build_img
    type         = "LINUX_CONTAINER"
    environment_variables = concat(var.codebuild_common_env_vars, [
      {
        name  = "TERRAFORM_VERSION"
        type  = "PLAINTEXT"
        value = var.terraform_version
      },
      {
        name  = "TERRAGRUNT_VERSION"
        type  = "PLAINTEXT"
        value = var.terragrunt_version
      },
      {
        # passes -s to curl to silence out
        name  = "TFENV_CURL_OUTPUT"
        type  = "PLAINTEXT"
        value = "0"
      },
      {
        name  = "SECONDARY_SOURCE_IDENTIFIER"
        type  = "PLAINTEXT"
        value = local.buildspec_scripts_source_identifier
      },
      {
        name  = "GITHUB_MERGE_LOCK_SSM_KEY"
        type  = "PLAINTEXT"
        value = aws_ssm_parameter.merge_lock.name
      },
      {
        name  = "TRIGGER_SF_FUNCTION_NAME"
        type  = "PLAINTEXT"
        value = local.trigger_sf_function_name
      },
      {
        name  = "METADB_NAME"
        type  = "PLAINTEXT"
        value = local.metadb_name
      },
      {
        name  = "METADB_CLUSTER_ARN"
        type  = "PLAINTEXT"
        value = aws_rds_cluster.metadb.arn
      },
      {
        name  = "METADB_SECRET_ARN"
        type  = "PLAINTEXT"
        value = aws_secretsmanager_secret_version.ci_metadb_user.arn
      }
      ], var.create_deploy_stack_graph_scan ? [{
        name  = "GRAPH_SCAN"
        type  = "PLAINTEXT"
        value = "true"
      }] : []
    )
  }

  webhook_filter_groups = [
    [
      {
        pattern = "PULL_REQUEST_MERGED"
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
  vpc_config = var.create_deploy_stack_vpc_config

  role_policy_arns = [
    aws_iam_policy.merge_lock_ssm_param_full_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
    var.tf_state_read_access_policy
  ]

  role_policy_statements = [
    {
      sid       = "SSMParamMergeLockAccess"
      effect    = "Allow"
      actions   = ["ssm:PutParameter"]
      resources = [aws_ssm_parameter.merge_lock.arn]
    },
    {
      sid       = "CrossAccountTerraformPlanAccess"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = flatten([for account in var.account_parent_cfg : account.plan_role_arn])
    },
    {
      sid       = "LambdaTriggerSFAccess"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = [module.lambda_trigger_sf.function_arn]
    }
  ]
}

module "codebuild_pr_plan" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = local.pr_plan_build_name

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = local.build_img
    type         = "LINUX_CONTAINER"
    environment_variables = concat(var.pr_plan_env_vars, var.codebuild_common_env_vars, [
      {
        name  = "TERRAFORM_VERSION"
        type  = "PLAINTEXT"
        value = var.terraform_version
      },
      {
        name  = "TERRAGRUNT_VERSION"
        type  = "PLAINTEXT"
        value = var.terragrunt_version
      },
      {
        # passes -s to curl to silence out
        name  = "TFENV_CURL_OUTPUT"
        type  = "PLAINTEXT"
        value = "0"
      },
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
        name  = "METADB_NAME"
        value = local.metadb_name
        type  = "PLAINTEXT"
      },
      {
        name  = "METADB_CLUSTER_ARN"
        value = aws_rds_cluster.metadb.arn
        type  = "PLAINTEXT"
      },
      {
        name  = "METADB_SECRET_ARN"
        value = aws_secretsmanager_secret_version.ci_metadb_user.arn
        type  = "PLAINTEXT"
      },
      {
        name  = "ACCOUNT_DIM"
        value = "${jsonencode(var.account_parent_cfg)}"
        type  = "PLAINTEXT"
      }
    ])
  }

  vpc_config = var.pr_plan_vpc_config

  source_version = var.base_branch

  artifacts = {
    type = "NO_ARTIFACTS"
  }

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

  build_source = {
    type                = "GITHUB"
    git_clone_depth     = 0
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = true
    build_status_config = {
      context = var.pr_plan_status_check_name
    }
    buildspec = <<-EOT
version: 0.2
env:
  shell: bash
phases:
  install:
    commands:
      - bash "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}/buildspecs/img/entrypoint.sh"
  build:
    commands:
      - python "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}/buildspecs/pr_plan/plan.py"
EOT
  }

  secondary_build_source = {
    source_identifier   = local.buildspec_scripts_source_identifier
    type                = "GITHUB"
    git_clone_depth     = 1
    report_build_status = false
    insecure_ssl        = false
    location            = data.github_repository.build_scripts.http_clone_url
    source_version      = local.terraform_module_version
  }
  role_policy_statements = [
    {
      sid       = "CrossAccountTerraformPlanAccess"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = flatten([for account in var.account_parent_cfg : account.plan_role_arn])
    }
  ]
}

module "codebuild_terra_run" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = local.terra_run_build_name

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = local.build_img
    type         = "LINUX_CONTAINER"
    environment_variables = concat(var.terra_run_env_vars, var.codebuild_common_env_vars, [
      {
        name  = "TERRAFORM_VERSION"
        type  = "PLAINTEXT"
        value = var.terraform_version
      },
      {
        name  = "TERRAGRUNT_VERSION"
        type  = "PLAINTEXT"
        value = var.terragrunt_version
      },
      {
        # passes -s to curl to silence out
        name  = "TFENV_CURL_OUTPUT"
        type  = "PLAINTEXT"
        value = "0"
      },
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
        name  = "METADB_NAME"
        value = local.metadb_name
        type  = "PLAINTEXT"
      },
      {
        name  = "METADB_CLUSTER_ARN"
        value = aws_rds_cluster.metadb.arn
        type  = "PLAINTEXT"
      },
      {
        name  = "METADB_SECRET_ARN"
        value = aws_secretsmanager_secret_version.ci_metadb_user.arn
        type  = "PLAINTEXT"
      }
    ])
  }

  vpc_config = var.terra_run_vpc_config

  source_version = var.base_branch
  artifacts = {
    type = "NO_ARTIFACTS"
  }
  build_source = {
    type                = "GITHUB"
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
    buildspec           = <<-EOT
version: 0.2
env:
  shell: bash
phases:
  install:
    commands:
      - bash "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}/buildspecs/img/entrypoint.sh"
      - pip install -e "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}"
  build:
    commands:
      - "$${TG_COMMAND}"
    finally:
      - python "$${CODEBUILD_SRC_DIR_${local.buildspec_scripts_source_identifier}}/buildspecs/terra_run/update_new_resources.py"
EOT
  }
  secondary_build_source = {
    source_identifier   = local.buildspec_scripts_source_identifier
    type                = "GITHUB"
    git_clone_depth     = 1
    report_build_status = false
    insecure_ssl        = false
    location            = data.github_repository.build_scripts.http_clone_url
    source_version      = local.terraform_module_version
  }
  role_policy_statements = [
    {
      sid       = "CrossAccountTerraformPlanAndDeployAccess"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = flatten([for account in var.account_parent_cfg : [account.plan_role_arn, account.deploy_role_arn]])
    }
  ]
  role_policy_arns = [
    aws_iam_policy.ci_metadb_access.arn
  ]
}