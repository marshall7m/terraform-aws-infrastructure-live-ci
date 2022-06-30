locals {
  terraform_module_version = trimspace(file("${path.module}/source_version.txt"))

  create_deploy_stack_build_name      = "${var.prefix}-create-deploy-stack"
  terra_run_build_name                = "${var.prefix}-terra-run"
  buildspec_scripts_source_identifier = "helpers"

  ecs_image_address = coalesce(
    var.ecs_image_address,
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
resource "aws_ssm_parameter" "metadb_ci_password" {
  name        = "${local.metadb_name}_${var.metadb_ci_username}"
  description = "Metadb password used by module's Codebuild projects"
  type        = "SecureString"
  value       = var.metadb_ci_password
}
module "codebuild_terra_run" {
  source = "github.com/marshall7m/terraform-aws-codebuild?ref=v0.1.0"
  name   = local.terra_run_build_name

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = local.ecs_image_address
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