terraform {
  # Variables in `backend`/`encryption` need >= 1.8; validations that
  # reference other variables need >= 1.9. Tested with 1.9.4 and 1.13.2.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.20.7"
    }
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.18.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # State lives in the org's own account. The bucket and the KMS key are
  # created once by scripts/bootstrap.sh; agents can't see either of them.
  backend "s3" {
    bucket       = "${var.org}-terraform-state"
    key          = "agents/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
  }

  # Native OpenTofu state/plan encryption. The data key is wrapped by the
  # org's KMS key, which only the admin can use. `enforced` refuses to ever
  # write an unencrypted state or plan.
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
