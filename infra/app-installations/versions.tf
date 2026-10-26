terraform {
  # Same floor as the main stack (variables in backend/encryption).
  required_version = ">= 1.9.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # Same bucket and KMS key as the main stack, separate state object. Only an
  # admin (key user) can read it, like the main state.
  backend "s3" {
    bucket       = "${var.org}-terraform-state"
    key          = "app-installations/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
  }

  encryption {
    key_provider "aws_kms" "state" {
      kms_key_id = "alias/${var.org}-terraform-state"
      region     = var.aws_region
      key_spec   = "AES_256"
    }

    method "aes_gcm" "state" {
      keys = key_provider.aws_kms.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
