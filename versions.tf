terraform {
  required_version = ">=1.3.0"
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
    docker = {
      source  = "kreuzwerker/docker"
      version = ">=2.23.0"
    }
  }
}