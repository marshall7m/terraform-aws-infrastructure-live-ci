data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


module "ecr_testing_img" {
  source = "github.com/marshall7m/terraform-aws-ecr/modules//ecr-docker-img"

  create_repo = true
  cache = true
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
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [module.testing_kms.arn]
    },
    {
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
			logging = "DEFAULT"
    }
  }
}

resource "aws_efs_file_system" "testing" {
  creation_token = local.mut_id
}

resource "aws_efs_mount_target" "testing" {
  file_system_id = aws_efs_file_system.testing.id
  subnet_id      = module.vpc.public_subnets[0]
  security_groups = [aws_security_group.testing_efs.id]
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
    subnets         = [module.vpc.public_subnets[0]]
    security_groups = [aws_security_group.testing_ecs.id]
    assign_public_ip = true
  }
  wait_for_steady_state = true
}

resource "aws_cloudwatch_log_group" "testing" {
  name = "${local.mut_id}-ecs"
}

resource "aws_ecs_task_definition" "testing" {
  family                   = "integration-testing"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = module.testing_ecs_task_role.role_arn
  execution_role_arn       = module.testing_ecs_execution_role.role_arn
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  volume {
    name = "${local.mut_id}-source-repo"
    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.testing.id
      # transit_encryption      = "ENABLED"
      # transit_encryption_port = 2049
    }
  }
  container_definitions = jsonencode([{
    name  = "testing"
    image = module.ecr_testing_img.full_image_url
    linuxParameters = {
      initProcessEnabled = true
    }
		logConfiguration = {
			logDriver = "awslogs",
			options = {
				awslogs-group = aws_cloudwatch_log_group.testing.name
				awslogs-region = data.aws_region.current.name
				awslogs-stream-prefix = "testing"
			}
		}

    cpu    = 256
    memory = 512
  }])
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

resource "aws_security_group" "testing_ecs" {
  name        = "${local.mut_id}-integration-testing-ecs"
  description = "Allows internet access request from testing container"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Allows outbound HTTP request from container"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Allows outbound HTTPS request from container"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Allows EFS mount point access from testing container"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Allows EFS mount point access from testing container"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    # cidr_blocks = ["${chomp(data.http.my_ip.body)}/32"]
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "testing_efs" {
  name        = "${local.mut_id}-integration-testing-efs"
  description = "Allows inbound access from testing container"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allows EFS mounting from user within client VPN"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    security_groups = [aws_security_group.testing_vpn.id]
  }
}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

resource "aws_security_group" "testing_vpn" {
  name        = "${local.mut_id}-integration-testing-vpn"
  description = "Allows inbound VPN connection"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Inbound VPN connection"
    from_port = 443
    protocol = "UDP"
    to_port = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allows EFS mount point access from testing container"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    # cidr_blocks = ["${chomp(data.http.my_ip.body)}/32"]
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "testing_vpn" {
  source  = "DNXLabs/client-vpn/aws"
  version = "0.3.0"
  cidr = "172.31.0.0/16"
  name = local.mut_id
  vpc_id                        = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets
  security_group_id = aws_security_group.testing_vpn.id
  split_tunnel = true
}