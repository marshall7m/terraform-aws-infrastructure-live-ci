locals {
  mut = "infrastructure-ci"
  mut_id = "mut-${local.mut}-${random_id.default.id}"
}

provider "random" {}

resource "random_id" "default" {
  byte_length = 8
}

resource "github_repository" "test" {
  name        = local.mut_id
  description = "Test repo for mut: ${local.mut}"
  auto_init   = true
  visibility  = "public"
}

resource "github_repository_file" "test_push" {
  repository          = github_repository.test.name
  branch              = "master"
  file                = "test_cfg/main.tf"
  content             = <<EOF
resource "aws_ssm_parameter" "test" {
  name  = ${local.mut_id}
  type  = "String"
  value = "bar"
}
EOF
  commit_message      = "test ${local.mut_id}"
  overwrite_on_create = true
  depends_on = [
    module.mut_infrastructure_ci
  ]
}

module "tf_plan_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut}-tf-plan-role"
  trusted_entities = [module.mut_infrastructure_ci.codepipeline_role_arn]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

module "tf_apply_role" {
  source                  = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"
  role_name               = "${local.mut}-tf-apply-role"
  trusted_entities = [module.mut_infrastructure_ci.codepipeline_role_arn]
  custom_role_policy_arns = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

data "aws_caller_identity" "current" {}

module "mut_infrastructure_ci" {
  source        = "..//"
  account_id    = data.aws_caller_identity.current.id
  pipeline_name = local.mut_id
  
  plan_cmd = "terraform plan"
  apply_cmd = "terraform apply -auto-approve"

  build_assumable_role_arns = [
    module.tf_plan_role.role_arn,
    module.tf_apply_role.role_arn
  ]

  repo_id = github_repository.test.full_name
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