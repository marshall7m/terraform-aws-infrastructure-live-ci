terraform {
  required_version = ">=1.0.0"
  experiments      = [module_variable_optional_attrs]
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
  }
}