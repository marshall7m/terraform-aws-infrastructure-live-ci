locals {
  metadb_name     = coalesce(var.metadb_name, replace("${var.step_function_name}", "-", "_"))
  metadb_username = coalesce(var.metadb_username, "${local.metadb_name}_user")
}

data "aws_subnet" "codebuilds" {
  count = length(local.codebuild_vpc_config.subnets)
  id    = local.codebuild_vpc_config.subnets[count.index]
}

resource "aws_security_group" "metadb" {
  name        = local.metadb_name
  description = "Allows Postgres connections from instances within private subnets"
  vpc_id      = var.codebuild_vpc_config.vpc_id

  ingress {
    description = "Allows postgres inbound traffic"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    #use cb sg id instead?
    cidr_blocks = data.aws_subnet.codebuilds[*].cidr_block
  }
}

resource "aws_rds_cluster" "metadb" {
  cluster_identifier = replace("${local.metadb_name}-cluster", "_", "-")
  engine             = "aurora-postgresql"
  availability_zones = var.metadb_availability_zones
  database_name      = local.metadb_name
  master_username    = local.metadb_username
  master_password    = var.metadb_password
  # must be >= 12.0 to allow `GENERATED AS ALWAYS` for execution table columns
  # engine_version                      = "default.aurora-postgresql10"
  port        = var.metadb_port
  engine_mode = "serverless"
  scaling_configuration {
    min_capacity = 2
  }

  # set to true for integration testing's db connection
  enable_http_endpoint = var.enable_metadb_http_endpoint

  skip_final_snapshot = true
  #TODO: not available for serverless V1-V2. Add once available
  # iam_database_authentication_enabled = true

  vpc_security_group_ids = concat([aws_security_group.metadb.id], var.metadb_security_group_ids)
  db_subnet_group_name   = var.metadb_subnets_group_name
}

resource "null_resource" "metadb_setup" {
  provisioner "local-exec" {
    command = "psql -f ${path.module}/sql/create_metadb_tables.sql; psql -f ${path.module}/sql/create_metadb_user.sql; "
    environment = {
      PGUSER     = local.metadb_username
      PGPASSWORD = var.metadb_password
      PGDATABASE = local.metadb_name
      PGHOST     = aws_rds_cluster.metadb.endpoint
      PGPORT     = var.metadb_port

      PG_SCHEMA = "private"

      CI_USER     = var.metadb_ci_username
      CI_PASSWORD = var.metadb_ci_password
    }
  }
  depends_on = [aws_rds_cluster.metadb]
}