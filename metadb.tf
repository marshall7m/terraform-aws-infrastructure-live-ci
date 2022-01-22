locals {
  metadb_name     = coalesce(var.metadb_name, replace("${var.step_function_name}", "-", "_"))
  metadb_username = coalesce(var.metadb_username, "${local.metadb_name}_user")
}

resource "aws_rds_cluster" "metadb" {
  cluster_identifier = replace("${local.metadb_name}-cluster", "_", "-")
  engine             = "aurora-postgresql"
  availability_zones = var.metadb_availability_zones
  database_name      = local.metadb_name
  master_username    = var.metadb_username
  master_password    = var.metadb_password
  # must be >= 12.0 to allow `GENERATED AS ALWAYS` for execution table columns
  # engine_version                      = "default.aurora-postgresql10"
  port        = var.metadb_port
  engine_mode = "serverless"
  scaling_configuration {
    min_capacity = 2
  }

  skip_final_snapshot = true
  #TODO: not available for serverless V1-V2. Add once available
  # iam_database_authentication_enabled = true

  vpc_security_group_ids = var.metadb_security_group_ids
  db_subnet_group_name   = var.metadb_subnets_group_name
}

# resource "aws_rds_cluster_instance" "metadb" {
#   identifier         = replace(local.metadb_name, "_", "-")
#   cluster_identifier = aws_rds_cluster.metadb.id
#   instance_class     = "db.t4g.medium"
#   engine             = aws_rds_cluster.metadb.engine
#   engine_version     = aws_rds_cluster.metadb.engine_version
# }

resource "null_resource" "metadb_setup" {
  provisioner "local-exec" {
    command = "psql -f ${path.module}/sql/create_metadb_tables.sql; psql -c \"CREATE USER ${local.metadb_username}; GRANT rds_iam TO ${local.metadb_username};\""
    environment = {
      PGUSER     = local.metadb_username
      PGPASSWORD = var.metadb_password
      PGDATABASE = local.metadb_name
      PGHOST     = aws_rds_cluster.metadb.endpoint
      PGPORT     = var.metadb_port
    }
  }
  depends_on = [aws_rds_cluster.metadb]
}