# Admin credentials come from the environment, never from tfvars:
#   AWS:       AWS_PROFILE (or AWS_ACCESS_KEY_ID/...) of the admin
#   Infisical: INFISICAL_UNIVERSAL_AUTH_CLIENT_ID / _SECRET of an admin identity
#   Neon:      NEON_API_KEY
#   GitHub:    GITHUB_TOKEN of an org owner (user token: adding repos to an
#              App installation is not allowed with an App token)

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      managed-by = "agent-onboarding"
    }
  }
}

provider "infisical" {
  host = var.infisical_host
}

provider "neon" {}

provider "github" {
  owner = var.github_org
}
