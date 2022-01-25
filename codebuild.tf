locals {
  plan_role_name  = coalesce(var.plan_role_name, "${var.step_function_name}-tf-plan")
  apply_role_name = coalesce(var.apply_role_name, "${var.step_function_name}-tf-apply")
  merge_lock_name = coalesce(var.merge_lock_build_name, "${var.step_function_name}-merge-lock")

  trigger_step_function_build_name    = coalesce(var.merge_lock_build_name, "${var.step_function_name}-trigger-sf")
  terra_run_build_name                = coalesce(var.merge_lock_build_name, "${var.step_function_name}-terra-run")
  buildspec_scripts_source_identifier = "helpers"
  codebuild_vpc_config                = merge(var.codebuild_vpc_config, { "security_group_ids" = [aws_security_group.codebuilds.id] })
}
data "github_repository" "this" {
  full_name = var.repo_full_name
}

data "github_repository" "build_scripts" {
  full_name = "marshall7m/terraform-aws-infrastructure-live-ci"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_security_group" "codebuilds" {
  name_prefix = "${var.step_function_name}-codebuilds"
  description = "Allows Codebuild projects to download associated repository source"
  vpc_id      = var.codebuild_vpc_config.vpc_id

  egress {
    description = "Allows HTTPS outbound traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ssm_parameter" "merge_lock" {
  name        = local.merge_lock_name
  description = "Locks PRs with infrastructure changes from being merged into base branch"
  type        = "String"
  value       = false
}

data "aws_ssm_parameter" "github_token" {
  name = var.github_token_ssm_key
}

data "aws_iam_policy_document" "merge_lock_ssm_param_access" {
  statement {
    sid    = "GetSSMParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameters"
    ]
    resources = [
      aws_ssm_parameter.merge_lock.arn,
      data.aws_ssm_parameter.github_token.arn
    ]
  }
}

resource "aws_iam_policy" "merge_lock_ssm_param_access" {
  name        = "${aws_ssm_parameter.merge_lock.name}-ssm-access"
  description = "Allows read access to merge lock ssm param"
  policy      = data.aws_iam_policy_document.merge_lock_ssm_param_access.json
}

data "aws_iam_policy_document" "codebuild_vpc_access" {
  statement {
    sid    = "VPCAcess"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterfacePermission"
    ]
    resources = ["arn:aws:ec2:region:account-id:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values   = [for subnet in local.codebuild_vpc_config.subnets : "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:subnet/${subnet}"]
    }
  }
}

resource "aws_iam_policy" "codebuild_vpc_access" {
  name        = "${local.codebuild_vpc_config.vpc_id}-codebuild-access"
  description = "Allows Codebuild services to connect to VPC"
  policy      = data.aws_iam_policy_document.codebuild_vpc_access.json
}

data "aws_iam_policy_document" "ci_metadb_access" {
  statement {
    sid    = "MetaDBConnectAccess"
    effect = "Allow"
    actions = [
      "rds-db:connect"
    ]
    resources = [
      "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:dbuser:${local.metadb_name}/${local.metadb_username}"
    ]
  }
}
resource "aws_iam_policy" "ci_metadb_access" {
  name        = replace("${local.metadb_name}-access", "_", "-")
  description = "Allows CI services to connect to metadb"
  policy      = data.aws_iam_policy_document.ci_metadb_access.json
}

module "ecr_terra_run" {
  count  = var.terra_run_img == null ? 1 : 0
  source = "github.com/marshall7m/terraform-aws-ecr/modules//ecr-docker-img"

  create_repo      = true
  codebuild_access = true
  source_path      = "${path.module}/buildspecs/terra_run"
  repo_name        = local.terra_run_build_name
  tag              = "latest"
  trigger_build_paths = [
    "${path.module}/buildspecs/terra_run"
  ]
  build_args = {
    TERRAFORM_VERSION  = var.terraform_version
    TERRAGRUNT_VERSION = var.terragrunt_version
  }
}

module "ecr_trigger_sf" {
  source = "github.com/marshall7m/terraform-aws-ecr/modules//ecr-docker-img"

  create_repo      = true
  codebuild_access = true
  source_path      = "${path.module}/buildspecs/trigger_sf"
  repo_name        = local.trigger_step_function_build_name
  tag              = "latest"
  trigger_build_paths = [
    "${path.module}/buildspecs/trigger_sf"
  ]
  build_args = {
    TERRAFORM_VERSION  = var.terraform_version
    TERRAGRUNT_VERSION = var.terragrunt_version
  }
}

module "plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = local.plan_role_name
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
  role_name               = local.apply_role_name
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


module "codebuild_merge_lock" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = local.merge_lock_name

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:3.0"
    type         = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "REPO_FULL_NAME"
        value = data.github_repository.this.full_name
        type  = "PLAINTEXT"
      },
      {
        name  = "PGUSER"
        type  = "PLAINTEXT"
        value = local.metadb_username
      },
      {
        name  = "PGPORT"
        type  = "PLAINTEXT"
        value = var.metadb_port
      },
      {
        name  = "PGDATABASE"
        type  = "PLAINTEXT"
        value = local.metadb_name
      },
      {
        name  = "PGHOST"
        type  = "PLAINTEXT"
        value = aws_rds_cluster.metadb.endpoint
      }
    ]
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

  vpc_config = local.codebuild_vpc_config

  artifacts = {
    type = "NO_ARTIFACTS"
  }
  # use inline buildspec with formatted bash script instead of downloading secondary source resulting in longer download phase
  build_source = {
    type      = "GITHUB"
    location  = data.github_repository.this.http_clone_url
    buildspec = <<-EOT
version: 0.2
env:
  shell: bash
  parameter-store:
    MERGE_LOCK: ${aws_ssm_parameter.merge_lock.name}
    GITHUB_TOKEN: ${var.github_token_ssm_key}
phases:
  build:
    commands:
      - |
        ${replace(replace(file("${path.module}/buildspecs/merge_lock/merge_lock.bash"), "\t", "  "), "\n", "\n        ")}
EOT
  }

  role_policy_arns = [
    aws_iam_policy.merge_lock_ssm_param_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.codebuild_vpc_access.arn
  ]
}

module "codebuild_trigger_sf" {
  source = "github.com/marshall7m/terraform-aws-codebuild"

  name = local.trigger_step_function_build_name

  source_auth_token          = var.github_token_ssm_value
  source_auth_server_type    = "GITHUB"
  source_auth_type           = "PERSONAL_ACCESS_TOKEN"
  source_auth_ssm_param_name = var.github_token_ssm_key

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
  build:
    commands:
      - python "$${CODEBUILD_SRC_DIR}/../${split("/", data.github_repository.build_scripts.full_name)[1]}/buildspecs/trigger_sf/trigger_sf.py"
EOT
  }

  secondary_build_source = {
    source_identifier   = local.buildspec_scripts_source_identifier
    type                = "GITHUB"
    git_clone_depth     = 1
    report_build_status = false
    insecure_ssl        = false
    location            = data.github_repository.build_scripts.http_clone_url
    #TODO: use github tag after development
    source_version = "merge-trigger"
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = module.ecr_trigger_sf.full_image_url
    type         = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "STATE_MACHINE_ARN"
        value = local.state_machine_arn
        type  = "PLAINTEXT"
      },
      {
        name  = "SECONDARY_SOURCE_IDENTIFIER"
        type  = "PLAINTEXT"
        value = local.buildspec_scripts_source_identifier
      },
      {
        name  = "EVENTBRIDGE_RULE"
        type  = "PLAINTEXT"
        value = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:rule/${local.cloudwatch_event_rule_name}"
      },
      {
        name  = "PGUSER"
        type  = "PLAINTEXT"
        value = local.metadb_username
      },
      {
        name  = "PGPORT"
        type  = "PLAINTEXT"
        value = var.metadb_port
      },
      {
        name  = "PGDATABASE"
        type  = "PLAINTEXT"
        value = local.metadb_name
      },
      {
        name  = "PGHOST"
        type  = "PLAINTEXT"
        value = aws_rds_cluster.metadb.endpoint
      }
    ]
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
  vpc_config = local.codebuild_vpc_config

  role_policy_arns = [
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.codebuild_vpc_access.arn
  ]

  role_policy_statements = [
    {
      sid    = "StepFunctionTriggerAccess"
      effect = "Allow"
      actions = [
        "states:StartExecution",
        "states:StopExecution"
      ]
      resources = [local.state_machine_arn]
    },
    {
      sid       = "SSMParamMergeLockAccess"
      effect    = "Allow"
      actions   = ["ssm:PutParameter"]
      resources = [aws_ssm_parameter.merge_lock.arn]
    }
  ]
}


module "codebuild_terra_run" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = local.terra_run_build_name
  assumable_role_arns = [
    module.plan_role.role_arn,
    module.apply_role.role_arn
  ]
  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = coalesce(var.terra_run_img, module.ecr_terra_run[0].full_image_url)
    type         = "LINUX_CONTAINER"
    environment_variables = concat(var.terra_run_env_vars, [
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
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
    buildspec           = <<-EOT
version: 0.2
env:
  shell: bash
phases:
  build:
    commands:
      - "$${TG_COMMAND}"
EOT
  }
}