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

# provider "random" {}

# resource "random_id" "test" {
#     byte_length = 4
# }

