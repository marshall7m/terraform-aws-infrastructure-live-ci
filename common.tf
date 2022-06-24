locals {
  github_token_ssm_key = "${var.prefix}-github-token"
}

data "aws_ssm_parameter" "github_token" {
  count = var.create_github_token_ssm_param != true ? 1 : 0
  name  = var.github_token_ssm_key
}

resource "aws_ssm_parameter" "github_token" {
  count       = var.create_github_token_ssm_param ? 1 : 0
  name        = local.github_token_ssm_key
  description = var.github_token_ssm_description
  type        = "SecureString"
  value       = var.github_token_ssm_value
}


data "aws_iam_policy_document" "merge_lock_ssm_param_full_access" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    sid       = "SSMParamMergeLockAccess"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.merge_lock.arn]
  }
}

resource "aws_iam_policy" "merge_lock_ssm_param_full_access" {
  name        = "${aws_ssm_parameter.merge_lock.name}-ssm-full-access"
  description = "Allows read/write access to merge lock SSM Parameter Store value"
  policy      = data.aws_iam_policy_document.merge_lock_ssm_param_full_access.json
}

data "aws_iam_policy_document" "github_token_ssm_read_access" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }
  statement {
    sid    = "GetSSMParameter"
    effect = "Allow"
    actions = [
      "ssm:GetParameter"
    ]
    resources = [try(data.aws_ssm_parameter.github_token[0].arn, aws_ssm_parameter.github_token[0].arn)]
  }
}

resource "aws_iam_policy" "github_token_ssm_read_access" {
  name        = "${local.github_token_ssm_key}-read-access"
  description = "Allows read access to github token SSM Parameter Store value"
  policy      = data.aws_iam_policy_document.github_token_ssm_read_access.json
}

data "aws_iam_policy_document" "ci_metadb_access" {
  statement {
    sid    = "MetaDBAccess"
    effect = "Allow"
    actions = [
      "rds-data:ExecuteStatement",
      "rds-data:RollbackTransaction",
      "rds-data:CommitTransaction",
      "rds-data:BatchExecuteStatement",
      "rds-data:BeginTransaction"
    ]
    resources = [aws_rds_cluster.metadb.arn]
  }

  statement {
    sid       = "MetaDBSecretAccess"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret_version.ci_metadb_user.arn]
  }
}

resource "aws_iam_policy" "ci_metadb_access" {
  name        = replace("${local.metadb_name}-access", "_", "-")
  description = "Allows CI services to connect to metadb"
  policy      = data.aws_iam_policy_document.ci_metadb_access.json
}
