terraform {
  required_version = ">= 0.14.0"
  experiments      = [module_variable_optional_attrs]
  required_providers {
    github = {
      source  = "integrations/github"
      version = ">= 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.44"
    }
    random = {
      source  = "hashicorp/random"
      version = ">=3.2.0"
    }
  }
}