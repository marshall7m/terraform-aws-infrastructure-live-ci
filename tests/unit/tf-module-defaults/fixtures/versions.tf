terraform {
  required_version = ">=1.0.0"
  required_providers {
    github = {
      source  = "integrations/github"
      version = ">= 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.44"
    }
  }
}