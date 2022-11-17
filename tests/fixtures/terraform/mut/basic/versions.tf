terraform {
  required_version = ">=1.3.0"
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = ">=3.1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">=3.1.0"
    }
    github = {
      source  = "integrations/github"
      version = ">=4.9.3"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = ">=2.23.0"
    }
  }
}