locals {
  mut = "infrastructure-ci"
}

provider "random" {}

resource "random_id" "default" {
  byte_length = 8
}

resource "github_repository" "test" {
  name        = "${local.mut}-${random_id.default.id}"
  description = "Test repo for mut: ${local.mut}"
  auto_init   = true
  visibility  = "public"
}

resource "github_repository_file" "test_push" {
  repository          = github_repository.test.name
  branch              = "master"
  file                = "test_cfg/terragrunt.hcl"
  content             = "used for testing associated mut: ${local.mut}"
  commit_message      = "test mut-${local.mut}"
  overwrite_on_create = true
  depends_on = [
    module.mut_infrastructure_ci
  ]
}

module "tf_plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut}-valid-tf-plan-role"
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

module "tf_apply_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut}-valid-tf-apply-role"
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

data "aws_caller_identity" "current" {}

module "mut_infrastructure_ci" {
  source        = "..//"
  account_id    = data.aws_caller_identity.current.id
  pipeline_name = "${local.mut}-${random_id.default.id}"


  repo_id = github_repository.test.id
  branch  = "master"

  stages = [
    {
      name              = "test"
      paths             = ["test_cfg/"]
      tf_plan_role_arn  = module.tf_plan_role.role_arn
      tf_apply_role_arn = module.tf_apply_role.role_arn
      order             = 1
    }
  ]
}