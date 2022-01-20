locals {
  metadb_name     = coalesce(var.merge_lock_build_name, replace("${var.step_function_name}", "-", "_"))
  metadb_username = coalesce(var.merge_lock_build_name, replace("${var.step_function_name}_user", "-", "_"))
}

resource "aws_db_instance" "metadb" {
  allocated_storage = 16
  engine            = "postgres"
  # must be >= 12.0 to allow `GENERATED AS ALWAYS` for execution table columns
  engine_version                      = "13.3"
  instance_class                      = "db.t3.micro"
  name                                = local.metadb_name
  username                            = var.metadb_username
  password                            = var.metadb_password
  port                                = var.metadb_port
  iam_database_authentication_enabled = true
  skip_final_snapshot                 = true
  publicly_accessible                 = var.metadb_publicly_accessible
  vpc_security_group_ids              = var.metadb_security_group_ids
  db_subnet_group_name                = var.metadb_subnets_group_name
}

resource "null_resource" "metadb_setup" {
  provisioner "local-exec" {
    command = "psql -f ${path.module}/sql/create_metadb_tables.sql; psql -c \"CREATE USER ${local.metadb_username}; GRANT rds_iam TO ${local.metadb_username};\""
    environment = {
      PGUSER     = local.metadb_username
      PGPASSWORD = var.metadb_password
      PGDATABASE = local.metadb_name
      PGHOST     = aws_db_instance.metadb.address
      PGPORT     = var.metadb_port
    }
  }
  depends_on = [aws_db_instance.metadb]
}