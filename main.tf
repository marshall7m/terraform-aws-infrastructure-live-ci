locals {
  sns_subscription_list = concat([for entity in var.account_parent_cfg : setproduct([entity.name], entity.approval_emails)]...)
}

module "plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = var.plan_role_name
  trusted_services        = ["codebuild.amazonaws.com"]
  custom_role_policy_arns = var.plan_role_policy_arns
  statements = length(var.plan_role_assumable_role_arns) > 0 ? [
    {
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.plan_role_assumable_role_arns
    }
  ] : []
}

module "apply_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = var.apply_role_name
  trusted_services        = ["codebuild.amazonaws.com"]
  custom_role_policy_arns = var.apply_role_policy_arns
  statements = length(var.apply_role_assumable_role_arns) > 0 ? [
    {
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = var.apply_role_assumable_role_arns
    }
  ] : []
}

module "codebuild_terraform_deploy" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = var.build_name
  assumable_role_arns = [
    module.plan_role.role_arn,
    module.apply_role.role_arn
  ]
  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:3.0"
    type         = "LINUX_CONTAINER"
    environment_variables = concat(var.build_env_vars, [
      {
        name  = "TF_IN_AUTOMATION"
        value = "true"
        type  = "PLAINTEXT"
      },
      {
        name  = "TF_INPUT"
        value = "false"
        type  = "PLAINTEXT"
      }
    ])
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }
  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_ci.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
  }
}

data "github_repository" "this" {
  name = var.repo_name
}

module "codebuild_rollback_provider" {
  source = "github.com/marshall7m/terraform-aws-codebuild"
  name   = var.get_rollback_providers_build_name
  assumable_role_arns = [
    module.plan_role.role_arn
  ]
  environment = {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:3.0"
    type         = "LINUX_CONTAINER"
    environment_variables = [
      {
        name  = "TERRAGRUNT_WORKING_DIR"
        type  = "PLAINTEXT"
        value = var.terragrunt_parent_dir
      }
    ]
  }

  artifacts = {
    type = "NO_ARTIFACTS"
  }
  build_source = {
    type                = "GITHUB"
    buildspec           = file("${path.module}/buildspec_rollback_new_provider.yaml")
    git_clone_depth     = 1
    insecure_ssl        = false
    location            = data.github_repository.this.http_clone_url
    report_build_status = false
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "sns_approval" {
  policy_id = "__default_policy_ID"

  statement {
    sid = "__default_statement_ID"

    effect = "Allow"

    actions = [
      "SNS:Subscribe",
      "SNS:SetTopicAttributes",
      "SNS:RemovePermission",
      "SNS:Receive",
      "SNS:Publish",
      "SNS:ListSubscriptionsByTopic",
      "SNS:GetTopicAttributes",
      "SNS:DeleteTopic",
      "SNS:AddPermission"
    ]

    resources = [for name in var.account_parent_cfg[*].name : aws_sns_topic.approval[name].arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"

      values = [
        data.aws_caller_identity.current.id
      ]
    }

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

}

resource "aws_sns_topic" "approval" {
  for_each        = toset([for entity in var.account_parent_cfg : entity.name])
  name            = "${var.step_function_name}-${each.value}-approval"
  delivery_policy = <<EOF
{
  "http": {
    "defaultHealthyRetryPolicy": {
      "minDelayTarget": 20,
      "maxDelayTarget": 20,
      "numRetries": 3,
      "numMaxDelayRetries": 0,
      "numNoDelayRetries": 0,
      "numMinDelayRetries": 0,
      "backoffFunction": "linear"
    },
    "disableSubscriptionOverrides": false
  }
}
  EOF
}

resource "aws_sns_topic_policy" "approval" {
  for_each = toset([for entity in var.account_parent_cfg : entity.name])
  arn      = aws_sns_topic.approval[each.value].arn

  policy = data.aws_iam_policy_document.sns_approval.json
}

resource "aws_sns_topic_subscription" "approval" {
  count     = length(local.sns_subscription_list)
  topic_arn = aws_sns_topic.approval[sns_subscription_list.test[count.index][0]].arn
  protocol  = "email"
  endpoint  = local.sns_subscription_list[count.index][1]
}