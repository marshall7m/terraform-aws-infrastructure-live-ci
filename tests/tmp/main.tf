provider "aws" {
    region = "us-west-2"
    alias = "sandbox"
}

data "aws_caller_identity" "sandbox" {
    provider = aws.sandbox
}

output "sandbox" {
    value = data.aws_caller_identity.sandbox.id
}

resource "aws_ssm_parameter" "sandbox" {
  name  = "foo"
  type  = "String"
  value = "bar"
  provider = aws.sandbox
}