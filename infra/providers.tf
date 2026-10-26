# Admin credentials come from the environment, never from tfvars. In the
# pipeline (README, "Pipeline") they are short-lived and issued per run:
#   AWS:       OIDC role via aws-actions/configure-aws-credentials (AWS_* env).
#              Backend and state encryption use the same default chain, so
#              no AWS_PROFILE is needed. Locally (break-glass): AWS_PROFILE.
#   Infisical: admin identity of the pipeline. OIDC Auth with
#              INFISICAL_AUTH_METHOD=oidc, INFISICAL_MACHINE_IDENTITY_ID and the
#              GitHub JWT in INFISICAL_AUTH_JWT; or Universal Auth with
#              INFISICAL_UNIVERSAL_AUTH_CLIENT_ID / _SECRET.
#   Neon:      NEON_API_KEY
#   GitHub:    GITHUB_TOKEN, an installation token of the overlens-infra-admin
#              App. App installations (which need an owner's user token) live
#              in infra/app-installations/, outside the pipeline.

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
