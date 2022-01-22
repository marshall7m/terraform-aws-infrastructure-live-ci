locals {
  mut_id           = "mut-terraform-aws-infrastructure-live-ci-${random_string.this.result}"
  database_subnets = ["10.0.101.0/24", "10.0.102.0/24"]
  private_subnets  = ["10.0.1.0/24"]
  public_subnets   = ["10.0.21.0/24"]

  ssh_key_name = "testing"
}

resource "random_string" "this" {
  length      = 10
  min_numeric = 5
  special     = false
  lower       = true
  upper       = false
}

resource "github_repository" "test" {
  name        = local.mut_id
  description = "Test repo for mut: ${local.mut_id}"
  visibility  = "public"
  template {
    owner      = "marshall7m"
    repository = "infrastructure-live-testing-template"
  }
}

resource "random_password" "metadb" {
  length  = 16
  special = false
}

module "mut_infrastructure_live_ci" {
  source = "../.."

  plan_role_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  apply_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]

  repo_full_name = github_repository.test.full_name
  base_branch    = "master"

  metadb_publicly_accessible = true
  metadb_username            = "mut_user"
  metadb_password            = random_password.metadb.result

  metadb_security_group_ids = [aws_security_group.metadb.id]
  metadb_subnets_group_name = module.vpc.database_subnet_group_name
  metadb_availability_zones = ["us-west-2a", "us-west-2b", "us-west-2c"]

  codebuild_vpc_config = {
    vpc_id             = module.vpc.vpc_id
    subnets            = module.vpc.private_subnets
    security_group_ids = [aws_security_group.codebuild.id]
  }

  create_github_token_ssm_param = false
  github_token_ssm_key          = "admin-github-token"

  approval_request_sender_email = "success@simulator.amazonses.com"
  account_parent_cfg = [
    {
      name                     = "dev"
      path                     = "dev-account"
      dependencies             = []
      voters                   = ["success@simulator.amazonses.com"]
      approval_count_required  = 1
      rejection_count_required = 1
    }
  ]

  depends_on = [
    github_repository.test
  ]
}

resource "aws_security_group" "metadb" {
  name        = "${local.mut_id}-codebuild"
  description = "Allows Postgres connections with private subnets services"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allows postgres inbound traffic"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }
}

resource "aws_security_group" "codebuild" {
  name_prefix = "${local.mut_id}-codebuild"
  description = "Allows Codebuild to download Github source"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Allows HTTPS outbound traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
    #replace with the IP address that is used to connect to EC2 instance
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "ecr_testing_img" {
  source = "github.com/marshall7m/terraform-aws-ecr/modules//ecr-docker-img"

  create_repo = true
  source_path = "${path.module}/../.."
  repo_name   = "${local.mut_id}-integration-testing"
  tag         = "latest"
  trigger_build_paths = [
    "${path.module}/../../Dockerfile",
    "${path.module}/../../entrypoint.sh",
    "${path.module}/../../setup.bash"
  ]
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
  file_permission      = "600"
  directory_permission = "700"
  sensitive_content    = tls_private_key.testing.private_key_pem
}

# using EC2 instance for testing since Aurora V1 DB clusters are only accessible within scope of VPC
# see at: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless.html
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

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = local.mut_id
  cidr = "10.0.0.0/16"
  azs  = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]

  public_subnets = local.public_subnets

  create_database_subnet_group   = true
  database_dedicated_network_acl = true
  database_inbound_acl_rules = [
    {
      rule_number = 1
      rule_action = "allow"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_block  = local.private_subnets[0]
    }
  ]
  database_subnet_group_name = "metadb"
  database_subnets           = local.database_subnets

  private_subnets               = local.private_subnets
  private_dedicated_network_acl = true
  private_outbound_acl_rules = [
    {
      rule_number = 1
      rule_action = "allow"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_block  = local.database_subnets[0]
    }
  ]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
}