#TODO: Add vars for VPC config (vpc_id, security_group) associated with CodeBuild projects and RDS metadb
# Add docs to remind user to make sure security groups allow inbound/outbound traffic from testing env for psql access
# if testing locally, make sure metadb is publicly available

data "aws_iam_policy_document" "metadb" {
  statement {
    effect    = "Allow"
    resources = [aws_db_instance.metadb.arn]
    #TODO: narrow permissions for cb to read/write
    actions = [
      "rds:*"
    ]
  }
}

resource "aws_iam_policy" "metadb" {
  name        = var.metadb_name
  description = "Read/write permissions for Codebuild"
  policy      = data.aws_iam_policy_document.metadb.json
}

resource "aws_db_instance" "metadb" {
  allocated_storage      = 16
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  name                   = var.metadb_name
  username               = var.metadb_username
  password               = var.metadb_password
  port                   = 5432
  skip_final_snapshot    = true
  publicly_accessible    = var.metadb_publicly_accessible
  vpc_security_group_ids = var.metadb_security_group_ids
  db_subnet_group_name   = var.metadb_subnets_group_name
}

resource "null_resource" "metadb_setup" {
  provisioner "local-exec" {
    command = "psql -f ${path.module}/sql/create_metadb_tables.sql"
    environment = {
      PGUSER     = var.metadb_username
      PGPASSWORD = var.metadb_password
      PGDATABASE = var.metadb_name
      PGHOST     = aws_db_instance.metadb.address
    }
  }
  depends_on = [aws_db_instance.metadb]
}