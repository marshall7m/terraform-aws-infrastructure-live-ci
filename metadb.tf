locals {
  metadb_name        = coalesce(var.metadb_name, replace("${var.step_function_name}", "-", "_"))
  cluster_identifier = replace("${var.step_function_name}-cluster", "_", "-")
  metadb_setup_script = <<EOF
  aws rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn ${aws_rds_cluster.metadb.arn} \
  --secret-arn ${aws_secretsmanager_secret_version.master_metadb_user.arn} \
  --database ${aws_rds_cluster.metadb.database_name} \
  --sql "${templatefile("${path.module}/sql/create_metadb_tables.sql", { metadb_schema = var.metadb_schema, metadb_name = local.metadb_name })}";

  aws rds-data execute-statement \
  --continue-after-timeout \
  --resource-arn ${aws_rds_cluster.metadb.arn} \
  --secret-arn ${aws_secretsmanager_secret_version.master_metadb_user.arn} \
  --database ${aws_rds_cluster.metadb.database_name} \
  --sql "${templatefile("${path.module}/sql/create_metadb_user.sql", {
  metadb_ci_username = var.metadb_ci_username
  metadb_ci_password = var.metadb_ci_password
  metadb_username    = var.metadb_username
  metadb_name        = local.metadb_name
  metadb_schema      = var.metadb_schema
  })}";

aws rds-data batch-execute-statement \
  --resource-arn ${aws_rds_cluster.metadb.arn} \
  --secret-arn ${aws_secretsmanager_secret_version.master_metadb_user.arn} \
  --database ${aws_rds_cluster.metadb.database_name} \
  --sql "
  INSERT INTO ${var.metadb_schema}.account_dim
  VALUES (
    :account_name, 
    :account_path, 
    CAST(:account_deps AS VARCHAR[]),
    :min_approval_count,
    :min_rejection_count,
    CAST(:voters AS VARCHAR[]),
    :plan_role_arn,
    :deploy_role_arn
  )
  ON CONFLICT (account_name) DO UPDATE SET
    account_path = EXCLUDED.account_path,
    account_deps = EXCLUDED.account_deps,
    min_approval_count = EXCLUDED.min_approval_count,
    min_rejection_count = EXCLUDED.min_rejection_count,
    voters = EXCLUDED.voters,
    plan_role_arn = EXCLUDED.plan_role_arn,
    deploy_role_arn = EXCLUDED.deploy_role_arn
    " \
  --parameter-sets "${replace(jsonencode([for account in var.account_parent_cfg :
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
        name  = "deploy_role_arn"
        value = { stringValue = account.deploy_role_arn }
      }
    ]
]), "\"", "\\\"")}"
EOF
}

data "aws_subnet" "codebuilds" {
  count = length(local.codebuild_vpc_config.subnets)
  id    = local.codebuild_vpc_config.subnets[count.index]
}

data "aws_subnet" "lambda" {
  count = length(var.lambda_subnet_ids)
  id    = var.lambda_subnet_ids[count.index]
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
    security_groups = concat(data.aws_subnet.codebuilds[*].cidr_block, data.aws_subnet.lambda[*].cidr_block)
  }
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

  # set to true for integration testing's db connection
  enable_http_endpoint = var.enable_metadb_http_endpoint
  skip_final_snapshot  = true
  #TODO: not available for serverless V1-V2. Add once available
  # iam_database_authentication_enabled = true

  vpc_security_group_ids = concat([aws_security_group.metadb.id], var.metadb_security_group_ids)
  db_subnet_group_name   = var.metadb_subnets_group_name
}

resource "aws_secretsmanager_secret" "master_metadb_user" {
  name = "${local.cluster_identifier}-data-api-master-credentials"
}

resource "aws_secretsmanager_secret_version" "master_metadb_user" {
  secret_id = aws_secretsmanager_secret.master_metadb_user.id
  secret_string = jsonencode({
    username = var.metadb_username
    password = var.metadb_password
  })
}

resource "aws_secretsmanager_secret_version" "ci_metadb_user" {
  secret_id = aws_secretsmanager_secret.master_metadb_user.id
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
  triggers = merge({ for file in formatlist("${path.module}/%s", fileset("${path.module}", "sql/*")) : basename(file) => filesha256(file) }, { setup_script = sha256(local.metadb_setup_script) })
}