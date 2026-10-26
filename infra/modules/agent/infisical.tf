# Machine identity of the agent (runbook §1). Its client ID/secret are the
# only credentials Multica stores; everything else lives in /<agent>.

locals {
  secret_path = var.agents_credentials.path_prefix == "/" ? "/${var.slug}" : "${var.agents_credentials.path_prefix}/${var.slug}"
}

resource "infisical_identity" "this" {
  name   = "agent-${var.slug}"
  org_id = var.infisical_org_id
  role   = var.org_role
}

resource "infisical_identity_universal_auth" "this" {
  identity_id                 = infisical_identity.this.id
  access_token_ttl            = var.universal_auth.access_token_ttl
  access_token_max_ttl        = var.universal_auth.access_token_max_ttl
  access_token_trusted_ips    = [for ip in var.universal_auth.trusted_ips : { ip_address = ip }]
  client_secret_trusted_ips   = [for ip in var.universal_auth.trusted_ips : { ip_address = ip }]
  access_token_num_uses_limit = 0
}

# Rotation: tofu apply -replace='module.agent["<agent>"].infisical_identity_universal_auth_client_secret.this'
# then scripts/sync-multica.sh. The old secret is revoked when replaced.
resource "infisical_identity_universal_auth_client_secret" "this" {
  identity_id = infisical_identity.this.id
  description = "Multica agent ${var.display_name} (managed by OpenTofu)"

  depends_on = [infisical_identity_universal_auth.this]
}

resource "infisical_project_identity" "agents_credentials" {
  project_id     = var.agents_credentials.project_id
  identity_id    = infisical_identity.this.id
  roles          = [{ role_slug = var.agents_credentials.isolate ? "no-access" : "member" }]
  adopt_existing = true
}

# With isolation on, the agent reads only its own folder.
resource "infisical_project_identity_specific_privilege" "own_folder" {
  count = var.agents_credentials.isolate ? 1 : 0

  project_slug = var.agents_credentials.project_slug
  identity_id  = infisical_identity.this.id
  slug         = "agent-${var.slug}-own-folder"

  permissions_v2 = [
    {
      subject = "secrets"
      action  = ["describeSecret", "readValue"]
      conditions = jsonencode({
        environment = { "$eq" = var.infisical_env }
        secretPath  = { "$glob" = "${local.secret_path}/**" }
      })
    },
    {
      subject = "secret-folders"
      action  = ["read"]
      conditions = jsonencode({
        environment = { "$eq" = var.infisical_env }
        secretPath  = { "$glob" = "${local.secret_path}/**" }
      })
    },
  ]

  depends_on = [infisical_project_identity.agents_credentials]
}

resource "infisical_project_identity" "app" {
  for_each = var.app_project_ids

  project_id     = each.value
  identity_id    = infisical_identity.this.id
  roles          = [{ role_slug = var.app_project_role }]
  adopt_existing = true
}

resource "infisical_secret_folder" "this" {
  count = var.folder_exists ? 0 : 1

  project_id       = var.agents_credentials.project_id
  environment_slug = var.infisical_env
  folder_path      = var.agents_credentials.path_prefix
  name             = var.slug
  # Offboarding removes the folder with whatever is left in it
  # (NOTION_TOKEN, GH_APP_PRIVATE_KEY, Railway tokens).
  force_delete = true

  depends_on = [terraform_data.agents_credentials_ready]
}

resource "terraform_data" "agents_credentials_ready" {
  input = var.agents_credentials_ready
}

# Credentials generated here go straight to /<agent>; nobody copies them.
locals {
  github_secrets = var.github == null ? {} : {
    GH_APP_ID              = tostring(data.github_app.this[0].id)
    GH_APP_INSTALLATION_ID = tostring(var.github.installation_id)
    GIT_AUTHOR_NAME        = local.bot_login
    GIT_COMMITTER_NAME     = local.bot_login
    GIT_AUTHOR_EMAIL       = local.bot_email
    GIT_COMMITTER_EMAIL    = local.bot_email
  }

  aws_secrets = var.aws == null ? {} : {
    AWS_ACCESS_KEY_ID     = aws_iam_access_key.this[0].id
    AWS_SECRET_ACCESS_KEY = aws_iam_access_key.this[0].secret
    AWS_ROLE_ARN          = var.aws.role_arn
    AWS_ROLE_SESSION_NAME = aws_iam_user.this[0].name
    AWS_REGION            = var.aws.region
  }

  # Keys are static so for_each is known at plan time even when values aren't.
  secret_names = toset(concat(keys(local.github_secrets), keys(local.aws_secrets)))
  secrets      = merge(local.github_secrets, local.aws_secrets)
}

resource "infisical_secret" "this" {
  for_each = local.secret_names

  workspace_id = var.agents_credentials.project_id
  env_slug     = var.infisical_env
  folder_path  = local.secret_path
  name         = each.key
  value        = local.secrets[each.key]

  depends_on = [infisical_secret_folder.this]
}
