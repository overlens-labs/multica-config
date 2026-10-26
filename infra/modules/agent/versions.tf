terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    infisical = {
      source  = "infisical/infisical"
      version = ">= 0.20.7"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.0"
    }
  }
}
