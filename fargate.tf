locals {
  ecs_cluster_name = "${var.prefix}-ecs"

  ecs_execution_role_name = "${var.prefix}-ecs-execution"
  ecs_tasks_context       = "${path.module}/docker"

  ecs_assign_public_ip      = var.ecs_assign_public_ip ? "ENABLED" : "DISABLED"
  pr_plan_task_family       = "${var.prefix}-pr-plan"
  pr_plan_container_name    = "plan"
  pr_plan_log_stream_prefix = "pr/${local.pr_plan_container_name}/"

  create_deploy_stack_family            = "${var.prefix}-create-deploy-stack"
  create_deploy_stack_container_name    = "create_stack"
  create_deploy_stack_logs_prefix       = "merge"
  create_deploy_stack_log_stream_prefix = "merge/${local.create_deploy_stack_container_name}/"

  terra_run_family         = "${var.prefix}-terra-run"
  terra_run_container_name = "run"
  terra_run_logs_prefix    = "sf"

  private_registry_auth_statement = var.private_registry_auth ? var.private_registry_custom_kms_key_arn != null ? {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "ssm:GetParameters",
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      local.private_registry_secret_manager_arn,
      var.private_registry_custom_kms_key_arn
    ]
    } : {
    effect = "Allow"
    actions = [
      "ssm:GetParameters",
      "secretsmanager:GetSecretValue"
    ]
    resources = [local.private_registry_secret_manager_arn]
  } : null

  private_registry_secret_manager_arn = var.private_registry_auth ? coalesce(var.private_registry_secret_manager_arn, try(aws_secretsmanager_secret_version.registry[0].arn, null)) : null

  ecs_tasks_base_env_vars = [
    {
      name  = "SOURCE_CLONE_URL"
      value = var.repo_clone_url
    },
    {
      name  = "REPO_FULL_NAME"
      value = local.repo_full_name
    },
    {
      name  = "TERRAFORM_VERSION"
      value = var.terraform_version
    },
    {
      name  = "TERRAGRUNT_VERSION"
      value = var.terragrunt_version
    },
    {
      # passes -s to curl to silence out
      name  = "TFENV_CURL_OUTPUT"
      value = "0"
    },
    {
      name  = "TF_IN_AUTOMATION"
      value = "true"
    },
    {
      name  = "TF_INPUT"
      value = "false"
    },
  ]

  ecs_image_address      = try(docker_registry_image.ecr_ecs_tasks[0].name, var.ecs_image_address)
  repository_credentials = local.private_registry_secret_manager_arn != null ? { credentialsParameter = local.private_registry_secret_manager_arn } : null
}

module "ecr_ecs_tasks" {
  count                   = var.ecs_image_address == null ? 1 : 0
  source                  = "terraform-aws-modules/ecr/aws"
  version                 = "1.5.0"
  repository_name         = "${var.prefix}/tasks"
  repository_force_delete = true
  repository_type         = "private"
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 5 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 5
        },
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "docker_image" "ecr_ecs_tasks" {
  count        = var.ecs_image_address == null ? 1 : 0
  name         = "${module.ecr_ecs_tasks[0].repository_url}:${local.module_docker_img_tag}"
  keep_locally = true
  build {
    path     = local.ecs_tasks_context
    no_cache = true
  }
  triggers = { for f in fileset(local.ecs_tasks_context, "**") :
  f => filesha256(format("${local.ecs_tasks_context}/%s", f)) }
}

resource "docker_tag" "ecr_ecs_tasks" {
  count        = var.ecs_image_address == null ? 1 : 0
  source_image = docker_image.ecr_ecs_tasks[0].image_id
  target_image = "${module.ecr_ecs_tasks[0].repository_url}:${local.module_docker_img_tag}-${split(":", docker_image.ecr_ecs_tasks[0].image_id)[1]}"
}

resource "docker_registry_image" "ecr_ecs_tasks" {
  count = var.ecs_image_address == null ? 1 : 0
  name  = docker_tag.ecr_ecs_tasks[0].target_image
}

resource "aws_ssm_parameter" "scan_type" {
  name  = "${local.create_deploy_stack_family}-scan-type"
  type  = "String"
  value = var.create_deploy_stack_scan_type
}

resource "aws_ecs_cluster" "this" {
  name = local.ecs_cluster_name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

module "ecs_execution_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"
  role_name = local.ecs_execution_role_name
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.commit_status_config.arn
  ]
  statements = concat(local.private_registry_auth_statement != null ? [local.private_registry_auth_statement] : [],
    [
      {
        effect = "Allow"
        actions = [
          "ssm:GetParameters"
        ]
        resources = [aws_ssm_parameter.scan_type.arn]
      }
  ])
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

resource "aws_secretsmanager_secret" "registry" {
  count = var.private_registry_auth && var.create_private_registry_secret ? 1 : 0
  name  = "${var.prefix}-registry-creds"
}

resource "aws_secretsmanager_secret_version" "registry" {
  count     = var.private_registry_auth && var.create_private_registry_secret ? 1 : 0
  secret_id = aws_secretsmanager_secret.registry[0].id
  secret_string = jsonencode({
    username = var.registry_username
    password = var.registry_password
  })
}

resource "aws_cloudwatch_log_group" "ecs_tasks" {
  name              = "${local.ecs_cluster_name}-tasks"
  retention_in_days = var.ecs_task_logs_retention_in_days
}

module "pr_plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"
  role_name               = local.pr_plan_task_family
  custom_role_policy_arns = [aws_iam_policy.github_token_ssm_read_access.arn]
  trusted_services        = ["ecs-tasks.amazonaws.com"]
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.prefix}-ecs-tasks"
  description = "Allow no inbound traffic and all outbound traffic"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "pr_plan" {
  family = local.pr_plan_task_family
  container_definitions = jsonencode([
    {
      name                  = local.pr_plan_container_name
      essential             = true
      image                 = local.ecs_image_address
      command               = ["python", "/src/pr_plan/plan.py"]
      repositoryCredentials = local.repository_credentials
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        },
        {
          containerPort = 443
          hostPort      = 443
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_tasks.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "pr"
        }
      }
      secrets = [
        {
          name      = "GITHUB_TOKEN"
          valueFrom = local.github_token_arn
        },
        {
          name      = "COMMIT_STATUS_CONFIG"
          valueFrom = aws_ssm_parameter.commit_status_config.arn
        }
      ]
      environment = concat(
        [
          {
            name  = "LOG_URL_PREFIX"
            value = local.log_url_prefix
          },
          {
            name  = "LOG_STREAM_PREFIX"
            value = local.pr_plan_log_stream_prefix
          }
        ],
        local.ecs_tasks_base_env_vars,
        var.ecs_tasks_common_env_vars
      )
    }
  ])
  cpu                      = var.plan_cpu
  memory                   = var.plan_memory
  execution_role_arn       = module.ecs_execution_role.role_arn
  task_role_arn            = module.pr_plan_role.role_arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

module "create_deploy_stack_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"
  role_name = local.create_deploy_stack_family
  custom_role_policy_arns = [
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.merge_lock_ssm_param_full_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.ecs_write_logs.arn,
    aws_iam_policy.ecs_plan.arn,
    var.tf_state_read_access_policy
  ]
  statements = [
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
      resources = [module.lambda_trigger_sf.lambda_function_arn]
    }
  ]
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

resource "aws_ecs_task_definition" "create_deploy_stack" {
  family = local.create_deploy_stack_family
  container_definitions = jsonencode([
    {
      name                  = local.create_deploy_stack_container_name
      essential             = true
      image                 = local.ecs_image_address
      command               = ["python", "/src/create_deploy_stack/create_deploy_stack.py"]
      repositoryCredentials = local.repository_credentials
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        },
        {
          containerPort = 443
          hostPort      = 443
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_tasks.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "merge"
        }
      }

      secrets = [
        {
          name      = "GITHUB_TOKEN"
          valueFrom = local.github_token_arn
        },
        {
          name      = "SCAN_TYPE"
          valueFrom = aws_ssm_parameter.scan_type.arn
        },
        {
          name      = "COMMIT_STATUS_CONFIG"
          valueFrom = aws_ssm_parameter.commit_status_config.arn
        }
      ]

      environment = concat(local.ecs_tasks_base_env_vars, var.ecs_tasks_common_env_vars, [
        {
          name  = "GITHUB_MERGE_LOCK_SSM_KEY"
          value = aws_ssm_parameter.merge_lock.name
        },
        {
          name  = "SOURCE_VERSION"
          value = var.base_branch
        },
        {
          name  = "STATUS_CHECK_NAME"
          value = var.create_deploy_stack_status_check_name
        },
        {
          name  = "TRIGGER_SF_FUNCTION_NAME"
          value = local.trigger_sf_function_name
        },
        {
          name  = "METADB_NAME"
          value = local.metadb_name
        },
        {
          name  = "AURORA_CLUSTER_ARN"
          value = aws_rds_cluster.metadb.arn
        },
        {
          name  = "AURORA_SECRET_ARN"
          value = aws_secretsmanager_secret_version.ci_metadb_user.arn
        },
        {
          name  = "LOG_URL_PREFIX"
          value = local.log_url_prefix
        },
        {
          name  = "LOG_STREAM_PREFIX"
          value = local.create_deploy_stack_log_stream_prefix
        }
      ])
    }
  ])
  cpu                      = var.create_deploy_stack_cpu
  memory                   = var.create_deploy_stack_memory
  execution_role_arn       = module.ecs_execution_role.role_arn
  task_role_arn            = module.create_deploy_stack_role.role_arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

module "terra_run_plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"
  role_name = "${local.terra_run_family}-plan"
  custom_role_policy_arns = [
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.ecs_write_logs.arn,
    var.tf_state_read_access_policy
  ]
  statements = [
    {
      effect = "Allow"
      actions = [
        "states:SendTaskSuccess",
        "states:SendTaskFailure"
      ]
      resources = [local.state_machine_arn]
    }
  ]
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

module "terra_run_apply_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.2.0"
  role_name = local.terra_run_family
  custom_role_policy_arns = [
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.merge_lock_ssm_param_full_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.ecs_write_logs.arn,
    var.tf_state_read_access_policy
  ]
  statements = [
    {
      sid       = "CrossAccountTerraformApplyAccess"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.account_parent_cfg[*].apply_role_arn
    }
  ]
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

resource "aws_ecs_task_definition" "terra_run" {
  family = local.terra_run_family
  container_definitions = jsonencode([
    {
      name                  = local.terra_run_container_name
      essential             = true
      image                 = local.ecs_image_address
      command               = ["python", "/src/terra_run/run.py"]
      repositoryCredentials = local.repository_credentials
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        },
        {
          containerPort = 443
          hostPort      = 443
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_tasks.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = local.terra_run_logs_prefix
        }
      }

      secrets = [
        {
          name      = "GITHUB_TOKEN"
          valueFrom = local.github_token_arn
        },
        {
          name      = "COMMIT_STATUS_CONFIG"
          valueFrom = aws_ssm_parameter.commit_status_config.arn
        }
      ]

      environment = concat(local.ecs_tasks_base_env_vars, var.ecs_tasks_common_env_vars, [
        {
          name  = "SOURCE_VERSION"
          value = var.base_branch
        },
        {
          name  = "METADB_NAME"
          value = local.metadb_name
        },
        {
          name  = "AURORA_CLUSTER_ARN"
          value = aws_rds_cluster.metadb.arn
        },
        {
          name  = "AURORA_SECRET_ARN"
          value = aws_secretsmanager_secret_version.ci_metadb_user.arn
        },
        {
          name  = "LOG_URL_PREFIX"
          value = local.log_url_prefix
        },
        {
          name  = "LOG_STREAM_PREFIX"
          value = local.log_stream_prefix
        }
      ])
    }
  ])
  cpu                      = var.terra_run_cpu
  memory                   = var.terra_run_memory
  execution_role_arn       = module.ecs_execution_role.role_arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}