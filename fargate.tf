locals {
  ecs_execution_role_name  = "${var.prefix}-ecs-execution"
  plan_task_container_name = "${var.prefix}-pr-plan"
}

resource "aws_ecs_cluster" "this" {
  name = "${var.prefix}-ecs"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

module "ecs_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name               = local.ecs_execution_role_name
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
  trusted_services        = ["ecs-tasks.amazonaws.com"]
}

module "plan_role" {
  source    = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"
  role_name = local.plan_task_container_name
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
      resources = [aws_cloudwatch_log_group.plan.arn]
    }
  ]
  trusted_services = ["ecs-tasks.amazonaws.com"]
}

resource "aws_cloudwatch_log_group" "plan" {
  name = "${var.prefix}-pr-plan"
}

resource "aws_ecs_task_definition" "plan" {
  family = "${var.prefix}-pr-plan"
  container_definitions = jsonencode([
    {
      name      = local.plan_task_container_name
      essential = true
      image     = local.ecs_image_address
      command   = ["python", "/src/pr_plan/plan.py"]
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
          awslogs-group         = aws_cloudwatch_log_group.plan.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "pr"
        }
      }
      environment = concat(var.pr_plan_env_vars, var.codebuild_common_env_vars, [
        {
          name  = "SOURCE_VERSION"
          value = var.base_branch
        },
        {
          name  = "SOURCE_CLONE_URL"
          value = data.github_repository.this.http_clone_url
        },
        {
          name  = "STATUS_CHECK_NAME"
          value = var.pr_plan_status_check_name
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
        },
        {
          name  = "ACCOUNT_DIM"
          value = "${jsonencode(var.account_parent_cfg)}"
        }
      ])
    }
  ])
  cpu                      = var.plan_cpu
  memory                   = var.plan_memory
  execution_role_arn       = module.ecs_role.role_arn
  task_role_arn            = module.plan_role.role_arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}
