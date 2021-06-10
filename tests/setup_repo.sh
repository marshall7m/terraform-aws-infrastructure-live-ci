git clone "${clone_url}" && cd "$(basename "${clone_url}" .git)"

git init
mkdir baz bar foo

cat << "EOF" > "baz/main.tf"
variable "value" {
  description = "input value for AWS SSM parameter store value"
  type = string
}

resource "aws_ssm_parameter" "test" {
  name  = "mut-terraform-aws-infrastructure-live-ci"
  type  = "String"
  value = var.value
}

output "ssm_param" {
  value = aws_ssm_parameter.test.value
}
EOF

cat << "EOF" > "baz/terragrunt.hcl"
terraform {
    source = ".//"
}

inputs = {
    value = "baz"
}

EOF

cat << "EOF" > "bar/main.tf"
variable "dependency" {
    type = string
}

output "bar" {
  value = var.dependency
}

EOF

cat << "EOF" > "bar/terragrunt.hcl"
terraform {
    source = ".//"
}

dependency "baz" {
    config_path = "../baz"
}

inputs = {
    dependency = dependency.baz.outputs.ssm_param
}
EOF

cat << "EOF" > "foo/main.tf"
variable "dependency" {
    type = string
}

output "foo" {
  value = var.dependency
}

EOF

cat << "EOF" > "foo/terragrunt.hcl"
terraform {
    source = ".//"
}

dependency "bar" {
    config_path = "../bar"
}

inputs = {
    dependency = dependency.bar.outputs.bar
}
EOF

git add ./
git commit -m 'initial files'
git branch -M master
git remote add origin "${clone_url}"
git push -u origin master