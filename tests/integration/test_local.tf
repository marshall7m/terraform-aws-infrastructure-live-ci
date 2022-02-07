locals {
  ssh_key_name = "testing"
}

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

module "testing_ecs_execution_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut_id}-exec"
  trusted_services        = ["ecs-tasks.amazonaws.com"]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
}

module "testing_ecs_task_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut_id}-task"
  trusted_services        = ["ecs-tasks.amazonaws.com"]
  statements = [
    {
      sid    = "MetaDBConnectAccess"
      effect = "Allow"
      actions = ["rds-db:connect"]
      resources = [module.mut_infrastructure_live_ci.metadb_arn]
    }
  ]
}

resource "aws_ecs_cluster" "testing" {
  name = "${local.mut_id}-integration-testing"
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

  container_definitions = jsonencode([{
    name  = "testing"
    image = module.ecr_testing_img.full_image_url
    portMappings = [
      {
        hostPort = 22,
        protocol = "tcp"
        containerPort = 22
      }
    ]
    environment = [
      {
        name = "SSH_PUBLIC_KEY"
        value = tls_private_key.testing.public_key_openssh
      }
    ]
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
    description = "Allows SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.body)}/32"]
  }
}

resource "tls_private_key" "testing" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "testing" {
  key_name   = local.ssh_key_name
  public_key = tls_private_key.testing.public_key_openssh
}

resource "local_file" "testing_pem" {
  filename             = pathexpand("~/.ssh/${local.ssh_key_name}.pem")
  file_permission      = "400"
  directory_permission = "700"
  sensitive_content    = tls_private_key.testing.private_key_pem
}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

resource "aws_instance" "testing" {
  ami                         = "ami-066333d9c572b0680"
  instance_type               = "t3.medium"
  associate_public_ip_address = true
  key_name                    = aws_key_pair.testing.key_name

  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.testing.id]
}

resource "aws_iam_instance_profile" "testing" {
  name = "${local.mut_id}-testing-profile"
  role = module.ec2_testing_role.role_name
}

module "ec2_testing_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut_id}-testing"
  trusted_services        = ["ec2.amazonaws.com"]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

resource "aws_security_group" "testing" {
  name        = "testing-${local.mut_id}-ec2"
  description = "Allows SSH access to EC2 instance"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allows SSH access for testing EC2 instance"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.body)}/32"]
  }
}
