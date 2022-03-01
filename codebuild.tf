locals {
  #replace with var.prefix?
  merge_lock_name = coalesce(var.merge_lock_build_name, "${var.step_function_name}-merge-lock")

  trigger_step_function_build_name    = coalesce(var.merge_lock_build_name, "${var.step_function_name}-trigger-sf")
  terra_run_build_name                = coalesce(var.merge_lock_build_name, "${var.step_function_name}-terra-run")
  buildspec_scripts_source_identifier = "helpers"
  codebuild_vpc_config                = merge(var.codebuild_vpc_config, { "security_group_ids" = [aws_security_group.codebuilds.id] })
  cw_rule_initiator                   = "rule/${local.cloudwatch_event_rule_name}"
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

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

data "aws_ssm_parameter" "github_token" {
  name = var.github_token_ssm_key
}

data "aws_iam_policy_document" "merge_lock_ssm_param_access" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    sid    = "GetSSMParameter"
    effect = "Allow"
    actions = [
      "ssm:GetParameter"
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
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:network-interface/*"]
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

data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}

data "aws_iam_policy_document" "codebuild_ssm_access" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.metadb_ci_password.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [aws_ssm_parameter.metadb_ci_password.arn]
    }
  }
}

resource "aws_iam_policy" "codebuild_ssm_access" {
  name        = "${var.metadb_ci_username}-password-access"
  description = "Allows Codebuild services to read associated metadb user credentials"
  policy      = data.aws_iam_policy_document.codebuild_ssm_access.json
}

data "aws_iam_policy_document" "ci_metadb_access" {
  statement {
    sid    = "MetaDBConnectAccess"
    effect = "Allow"
    actions = [
      "rds-db:connect"
    ]
    resources = [
      "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:dbuser:${local.metadb_name}/${var.metadb_username}"
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
        value = var.metadb_ci_username
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
      },
      {
        name  = "MERGE_LOCK"
        type  = "PARAMETER_STORE"
        value = aws_ssm_parameter.merge_lock.name
      },
      {
        name  = "GITHUB_TOKEN"
        type  = "PARAMETER_STORE"
        value = var.github_token_ssm_key
      },
      {
        name  = "PGPASSWORD"
        type  = "PARAMETER_STORE"
        value = aws_ssm_parameter.metadb_ci_password.name
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
    aws_iam_policy.codebuild_vpc_access.arn,
    aws_iam_policy.codebuild_ssm_access.arn
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
    environment_variables = concat(var.codebuild_common_env_vars, [
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
        name  = "EVENTBRIDGE_FINISHED_RULE"
        type  = "PLAINTEXT"
        value = local.cw_rule_initiator
      },
      {
        name  = "PGUSER"
        type  = "PLAINTEXT"
        value = var.metadb_ci_username
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
      },
      {
        name  = "GITHUB_MERGE_LOCK_SSM_KEY"
        type  = "PLAINTEXT"
        value = aws_ssm_parameter.merge_lock.name
      },
      {
        name  = "PGPASSWORD"
        type  = "PARAMETER_STORE"
        value = aws_ssm_parameter.metadb_ci_password.name
      }
    ])
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
    aws_iam_policy.merge_lock_ssm_param_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.codebuild_vpc_access.arn,
    aws_iam_policy.codebuild_ssm_access.arn,
    var.tf_state_read_access_policy
  ]

  role_policy_statements = [
    {
      sid    = "StepFunctionAccess"
      effect = "Allow"
      actions = [
        "states:StartExecution",
        "states:StopExecution",
        "states:ListExecutions"
      ]
      resources = [local.state_machine_arn]
    },
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
      resources = [for account in var.account_parent_cfg : account.plan_role_arn]
    }
  ]
}


module "codebuild_terra_run" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = local.terra_run_build_name

  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = coalesce(var.terra_run_img, module.ecr_terra_run[0].full_image_url)
    type         = "LINUX_CONTAINER"
    environment_variables = concat(var.terra_run_env_vars, var.codebuild_common_env_vars, [
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
  build:
    commands:
      # serviceRoleOverride.$ within step function definition is not supported yet
      - |
        export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s" \
        $(aws sts assume-role \
        --role-arn "$${ROLE_ARN}" \
        --role-session-name ${local.terra_run_build_name} \
        --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
        --output text))
      - "$${TG_COMMAND}"
EOT
  }
  role_policy_statements = [
    {
      sid       = "CrossAccountTerraformPlanAndDeployAccess"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = flatten([for account in var.account_parent_cfg : [account.plan_role_arn, account.deploy_role_arn]])
    }
  ]
}