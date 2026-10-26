# One Postgres role per app, created only on the app's `dev` branch
# (runbook §4). Roles created on a child branch don't exist on main, and PR
# branches forked from dev inherit it. Agents never get a Neon API key: the
# connection string goes straight to the app's Infisical dev project.

locals {
  neon_apps = { for app, cfg in var.apps : app => cfg.neon if cfg.neon != null }
}

resource "neon_role" "agents" {
  for_each = local.neon_apps

  project_id = each.value.project_id
  branch_id  = each.value.branch_id
  name       = each.value.role_name
}

data "neon_branch_endpoints" "dev" {
  for_each = local.neon_apps

  project_id = each.value.project_id
  branch_id  = each.value.branch_id
}

# Works for imported roles too, whose password is not in state.
data "neon_branch_role_password" "agents" {
  for_each = local.neon_apps

  project_id = each.value.project_id
  branch_id  = each.value.branch_id
  role_name  = neon_role.agents[each.key].name
}

locals {
  neon_urls = {
    for app, cfg in local.neon_apps : app => {
      host = one([for e in data.neon_branch_endpoints.dev[app].endpoints : e.host if e.type == "read_write"])
      auth = "${urlencode(cfg.role_name)}:${urlencode(data.neon_branch_role_password.agents[app].password)}"
      db   = urlencode(cfg.database)
    }
  }
}

resource "infisical_secret" "database_url" {
  for_each = local.neon_urls

  workspace_id = infisical_project.app[each.key].id
  env_slug     = var.infisical_env
  folder_path  = "/"
  name         = "DATABASE_URL"
  # Pooled endpoint: "<endpoint>-pooler.<region>..." (Neon naming).
  value = "postgresql://${each.value.auth}@${replace(each.value.host, "/^([^.]+)\\./", "$1-pooler.")}/${each.value.db}?sslmode=require"

  depends_on = [infisical_project_environment.app]
}

resource "infisical_secret" "database_url_unpooled" {
  for_each = local.neon_urls

  workspace_id = infisical_project.app[each.key].id
  env_slug     = var.infisical_env
  folder_path  = "/"
  name         = "DATABASE_URL_UNPOOLED"
  value        = "postgresql://${each.value.auth}@${each.value.host}/${each.value.db}?sslmode=require"

  depends_on = [infisical_project_environment.app]
}
