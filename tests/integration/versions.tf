terraform {
  required_version = ">=1.0.0"
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">=3.1.0"
    }
    test = {
      source = "terraform.io/builtin/test"
    }
    github = {
      source  = "integrations/github"
      version = "4.9.3"
    }
    testing = {
      source  = "apparentlymart/testing"
      version = "0.0.2"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "3.1.0"
    }
  }
}