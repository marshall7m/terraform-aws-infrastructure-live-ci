locals {
  metadb_name        = coalesce(var.metadb_name, replace("${var.prefix}_metadb", "-", "_"))
  cluster_identifier = replace("${var.prefix}-cluster", "_", "-")
  metadb_setup_script = templatefile("${path.module}/sql/metadb_setup_script.sh", {
    tf_module_path    = path.module
    cluster_arn       = aws_rds_cluster.metadb.arn
    secret_arn        = aws_secretsmanager_secret_version.master_metadb_user.arn
    db_name           = aws_rds_cluster.metadb.database_name
    schema            = var.metadb_schema
    endpoint_url_flag = var.metadb_endpoint_url != null ? "--endpoint-url=${var.metadb_endpoint_url}" : ""
    create_tables_sql = templatefile("${path.module}/sql/create_metadb_tables.sql", {
      metadb_schema = var.metadb_schema,
      metadb_name   = local.metadb_name
    })
    create_ci_user_sql = templatefile("${path.module}/sql/create_metadb_user.sql", {
      metadb_ci_username = var.metadb_ci_username
      metadb_ci_password = var.metadb_ci_password
      metadb_username    = var.metadb_username
      metadb_name        = local.metadb_name
      metadb_schema      = var.metadb_schema
    })
    insert_account_dim_sql = templatefile("${path.module}/sql/insert_account_dim.sql", {
      metadb_schema = var.metadb_schema
    })
    insert_account_dim_parameter_sets = replace(jsonencode([for account in var.account_parent_cfg :
      [
        {
          name  = "account_name"
          value = { stringValue = account.name }
        },
        {
          name  = "account_path"
          value = { stringValue = account.path }
        },
        {
          name = "account_deps"
          value = {
            stringValue = "{${join(", ", account.dependencies)}}"
          }
        },
        {
          name  = "min_approval_count"
          value = { doubleValue = account.min_approval_count }
        },
        {
          name  = "min_rejection_count"
          value = { doubleValue = account.min_rejection_count }
        },
        {
          name = "voters"
          value = {
            stringValue = "{${join(", ", account.voters)}}"
          }
        },
        {
          name  = "plan_role_arn"
          value = { stringValue = account.plan_role_arn }
        },
        {
          name  = "apply_role_arn"
          value = { stringValue = account.apply_role_arn }
        }
      ]
    ]), "\"", "\\\"")
  })
}

resource "aws_ssm_parameter" "metadb_ci_password" {
  name        = "${local.metadb_name}_${var.metadb_ci_username}"
  description = "Metadb password used by ECS tasks"
  type        = "SecureString"
  value       = var.metadb_ci_password
}


# resource "aws_db_subnet_group" "metadb" {
#   count = var.create_metadb_subnet_group ? 1 : 0
#   name       = coalesce(var.metadb_subnet_group_name, local.cluster_identifier)
#   subnet_ids = var.metadb_subnet_ids
# }

resource "aws_security_group" "metadb" {
  name        = "${var.prefix}-metadb"
  description = "Allow no inbound/outbound traffic"
  vpc_id      = var.vpc_id
}

resource "aws_rds_cluster" "metadb" {
  cluster_identifier = local.cluster_identifier
  engine             = "aurora-postgresql"
  availability_zones = var.metadb_availability_zones
  database_name      = local.metadb_name
  master_username    = var.metadb_username
  master_password    = var.metadb_password
  port               = var.metadb_port
  engine_mode        = "serverless"
  scaling_configuration {
    min_capacity = 2
  }

  enable_http_endpoint = true
  skip_final_snapshot  = true

  vpc_security_group_ids = concat([aws_security_group.metadb.id], var.metadb_security_group_ids)
  # db_subnet_group_name   = try(aws_db_subnet_group.metadb[0].name, var.metadb_subnet_group_name)
  # db_subnet_group_name   = var.metadb_subnet_group_name

}

resource "random_id" "metadb_users" {
  byte_length = 8
}

resource "aws_secretsmanager_secret" "master_metadb_user" {
  name = "${local.cluster_identifier}-data-api-${var.metadb_username}-credentials"
}

resource "aws_secretsmanager_secret_version" "master_metadb_user" {
  secret_id = aws_secretsmanager_secret.master_metadb_user.id
  secret_string = jsonencode({
    username = var.metadb_username
    password = var.metadb_password
  })
}

resource "aws_secretsmanager_secret" "ci_metadb_user" {
  name = "${local.cluster_identifier}-data-api-${var.metadb_ci_username}-credentials"
}

resource "aws_secretsmanager_secret_version" "ci_metadb_user" {
  secret_id = aws_secretsmanager_secret.ci_metadb_user.id
  secret_string = jsonencode({
    username = var.metadb_ci_username
    password = var.metadb_ci_password
  })
}

resource "null_resource" "metadb_setup" {
  provisioner "local-exec" {
    command     = local.metadb_setup_script
    interpreter = ["bash", "-c"]
  }
  triggers = {
    metadb_setup_script = sha256(local.metadb_setup_script)
    cluster_arn         = aws_rds_cluster.metadb.arn
    db_name             = aws_rds_cluster.metadb.database_name
  }
}