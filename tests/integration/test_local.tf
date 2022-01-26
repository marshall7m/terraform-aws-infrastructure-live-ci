data "aws_caller_identity" "current" {}

module "ecr_testing_img" {
  source = "github.com/marshall7m/terraform-aws-ecr/modules//ecr-docker-img"

  create_repo = true
  source_path = "${path.module}/../.."
  repo_name   = "${local.mut_id}-integration-testing"
  tag         = "latest"
  trigger_build_paths = [
    "${path.module}/../../Dockerfile",
    "${path.module}/../../entrypoint.sh",
    "${path.module}/../../install.sh"
  ]
}

module "testing_kms" {
  source                           = "github.com/marshall7m/terraform-aws-kms/modules//cmk"
  trusted_admin_arns               = [data.aws_caller_identity.current.arn]
  trusted_service_usage_principals = ["ecs-tasks.amazonaws.com"]
}

module "testing_ecs_task_role" {
  source           = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name        = "${local.mut_id}-task"
  trusted_services = ["ecs-tasks.amazonaws.com"]
  statements = [
    {
      sid       = "test"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [module.testing_kms.arn]
    },
    {
      sid    = "quiz"
      effect = "Allow"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      resources = ["*"]
    }
  ]
}

module "testing_ecs_execution_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut_id}-exec"
  trusted_services        = ["ecs-tasks.amazonaws.com"]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
}

resource "aws_ecs_cluster" "testing" {
  name = "${local.mut_id}-integration-testing"

  configuration {
    execute_command_configuration {
      kms_key_id = module.testing_kms.arn
    }
  }
}

resource "aws_ecs_service" "testing" {
  name                   = "${local.mut_id}-integration-testing"
  task_definition        = aws_ecs_task_definition.testing.arn
  cluster                = aws_ecs_cluster.testing.id
  desired_count          = 0
  enable_execute_command = true
  launch_type            = "FARGATE"
  platform_version       = "1.4.0"
  network_configuration {
    subnets         = [module.vpc.private_subnets[0]]
    security_groups = [aws_security_group.testing.id]
  }
  wait_for_steady_state = true
}

# resource "aws_efs_file_system" "testing" {}

# resource "aws_efs_access_point" "testing" {}

resource "aws_ecs_task_definition" "testing" {
  family                   = "integration-testing"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = module.testing_ecs_task_role.role_arn
  execution_role_arn       = module.testing_ecs_execution_role.role_arn
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  container_definitions = jsonencode([{
    name  = "testing"
    image = module.ecr_testing_img.full_image_url
    linuxParameters = {
      initProcessEnabled = true
    }
    cpu    = 256
    memory = 512
  }])
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  #   volume {
  #     name = "source-repo"

  #     efs_volume_configuration {
  #       file_system_id          = aws_efs_file_system.testing.id
  #       root_directory          = "/src"
  #       transit_encryption      = "ENABLED"
  #       transit_encryption_port = 2999
  #       authorization_config {
  #         access_point_id = aws_efs_access_point.testing.id
  #         iam             = "ENABLED"
  #       }
  #     }
  #   }
}

resource "aws_security_group" "testing" {
  name        = "${local.mut_id}-integration-testing-ecs"
  description = "Allows internet access request from testing container"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Allows outbound HTTP access for installing packages within container"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Allows outbound HTTPS access for installing packages within container"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}