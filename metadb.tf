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
  allocated_storage   = 16
  engine              = "postgres"
  instance_class      = "db.t3.micro"
  name                = var.metadb_name
  username            = var.metadb_username
  password            = var.metadb_password
  port                = 5432
  skip_final_snapshot = true
}