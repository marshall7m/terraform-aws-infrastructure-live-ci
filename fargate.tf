locals {
  ecs_cluster_name = "${var.prefix}-ecs"

  ecs_execution_role_name = "${var.prefix}-ecs-execution"

  pr_plan_task_family    = "${var.prefix}-pr-plan"
  pr_plan_container_name = "plan"

  create_deploy_stack_family         = "${var.prefix}-create-deploy-stack"
  create_deploy_stack_container_name = "create-stack"

  terra_run_family         = "${var.prefix}-terra-run"
  terra_run_container_name = "run"
  terra_run_logs_prefix    = "run"

  private_registry_secret_manager_arn = coalesce(var.private_registry_secret_manager_arn, try(aws_secretsmanager_secret_version.registry[0].arn, null))

  ecs_tasks_base_env_vars = [
    {
      name  = "SOURCE_CLONE_URL"
      value = data.github_repository.this.http_clone_url
    },
    {
      name  = "REPO_FULL_NAME"
      value = data.github_repository.this.full_name
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

  terraform_module_version = trimspace(file("${path.module}/source_version.txt"))

  ecs_image_address = coalesce(
    var.ecs_image_address,
    "ghcr.io/marshall7m/terraform-aws-infrastructure-live:${local.terraform_module_version == "master" ? "latest" : local.terraform_module_version}"
  )
}

resource "aws_ecs_cluster" "this" {
  name = local.ecs_cluster_name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

module "ecs_execution_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name = local.ecs_execution_role_name
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
    aws_iam_policy.github_token_ssm_read_access.arn
  ]
  statements = [var.private_registry_custom_kms_key_arn != null ?
    {
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
    } :
    {
      effect = "Allow"
      actions = [
        "ssm:GetParameters",
        "secretsmanager:GetSecretValue"
      ]
      resources = [local.private_registry_secret_manager_arn]
    }
  ]
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

module "plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name               = local.pr_plan_task_family
  custom_role_policy_arns = [aws_iam_policy.github_token_ssm_read_access.arn]
  statements = [
    {
      sid       = "CrossAccountTerraformPlanAccess"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = flatten([for account in var.account_parent_cfg : account.plan_role_arn])
    },
    {
      effect = "Allow"
      actions = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      resources = [aws_cloudwatch_log_group.ecs_tasks.arn]
    }
  ]
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

resource "aws_ecs_task_definition" "plan" {
  family = local.pr_plan_task_family
  container_definitions = jsonencode([
    {
      name      = "plan"
      essential = true
      image     = local.ecs_image_address
      command   = ["python", "/src/pr_plan/plan.py"]
      repositoryCredentials = {
        credentialsParameter = local.private_registry_secret_manager_arn
      }
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
        }
      ]
      environment = concat(local.ecs_tasks_base_env_vars, var.ecs_tasks_common_env_vars)
    }
  ])
  cpu                      = var.plan_cpu
  memory                   = var.plan_memory
  execution_role_arn       = module.ecs_execution_role.role_arn
  task_role_arn            = module.plan_role.role_arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

module "create_deploy_stack_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name = local.create_deploy_stack_family
  custom_role_policy_arns = [
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.merge_lock_ssm_param_full_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
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
      effect = "Allow"
      actions = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      resources = [aws_cloudwatch_log_group.ecs_tasks.arn]
    },
    {
      sid       = "LambdaTriggerSFAccess"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = [module.lambda_trigger_sf.function_arn]
    }
  ]
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

resource "aws_ecs_task_definition" "create_deploy_stack" {
  family = local.create_deploy_stack_family
  container_definitions = jsonencode([
    {
      name      = local.create_deploy_stack_container_name
      essential = true
      image     = local.ecs_image_address
      command   = ["python", "/src/create_deploy_stack/create_deploy_stack.py"]
      repositoryCredentials = {
        credentialsParameter = local.private_registry_secret_manager_arn
      }
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
          name = "STATUS_CHECK_NAME"
          type = var.create_deploy_stack_status_check_name
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
          name  = "METADB_CLUSTER_ARN"
          value = aws_rds_cluster.metadb.arn
        },
        {
          name  = "METADB_SECRET_ARN"
          value = aws_secretsmanager_secret_version.ci_metadb_user.arn
          }], var.create_deploy_stack_graph_scan ? [{
          name  = "GRAPH_SCAN"
          value = "true"
        }] : []
      )
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

module "apply_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name = local.terra_run_family
  custom_role_policy_arns = [
    aws_iam_policy.github_token_ssm_read_access.arn,
    aws_iam_policy.merge_lock_ssm_param_full_access.arn,
    aws_iam_policy.ci_metadb_access.arn,
    var.tf_state_read_access_policy
  ]
  statements = [
    {
      sid       = "CrossAccountTerraformApplyAccess"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.account_parent_cfg[*].deploy_role_arn
    },
    {
      effect = "Allow"
      actions = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      resources = [aws_cloudwatch_log_group.ecs_tasks.arn]
    }
  ]
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

resource "aws_ecs_task_definition" "terra_run" {
  family = local.terra_run_family
  container_definitions = jsonencode([
    {
      name      = local.terra_run_container_name
      essential = true
      image     = local.ecs_image_address
      command   = ["python", "/src/create_deploy_stack/create_deploy_stack.py"]
      repositoryCredentials = {
        credentialsParameter = local.private_registry_secret_manager_arn
      }
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
          name  = "METADB_CLUSTER_ARN"
          value = aws_rds_cluster.metadb.arn
        },
        {
          name  = "METADB_SECRET_ARN"
          value = aws_secretsmanager_secret_version.ci_metadb_user.arn
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