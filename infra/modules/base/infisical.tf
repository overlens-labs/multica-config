# Infisical projects: one `agents-credentials` (a folder per agent) and one
# `<app>-dev` per app. These projects only ever have the dev environment;
# staging/prod secrets stay in each app's own project, which agents never join.

locals {
  app_project_slugs = { for app, cfg in var.apps : app => coalesce(cfg.infisical_project_slug, "${app}-dev") }

  # Only one folder level is supported for the prefix (e.g. "/agents").
  prefix_folder = trimprefix(var.agents_credentials.path_prefix, "/")
}

resource "infisical_project" "agents_credentials" {
  name                       = var.agents_credentials.name
  slug                       = var.agents_credentials.slug
  description                = "Per-agent tool credentials (one folder per agent). Managed by OpenTofu."
  should_create_default_envs = false
  has_delete_protection      = true

  lifecycle {
    prevent_destroy = true
    # Create-time only settings; never replace an adopted project over them.
    ignore_changes = [should_create_default_envs, template_name, description]
  }
}

resource "infisical_project_environment" "agents_credentials" {
  count = var.agents_credentials_imported ? 0 : 1

  project_id = infisical_project.agents_credentials.id
  name       = "Development"
  slug       = var.infisical_env
}

resource "infisical_secret_folder" "agents_prefix" {
  count = local.prefix_folder == "" ? 0 : 1

  project_id       = infisical_project.agents_credentials.id
  environment_slug = var.infisical_env
  folder_path      = "/"
  name             = local.prefix_folder

  depends_on = [infisical_project_environment.agents_credentials]
}

resource "infisical_project" "app" {
  for_each = local.app_project_slugs

  name                       = each.value
  slug                       = each.value
  description                = "Dev-only secrets of ${each.key} for AI agents. Managed by OpenTofu."
  should_create_default_envs = false
  has_delete_protection      = true

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [should_create_default_envs, template_name, description]
  }
}

resource "infisical_project_environment" "app" {
  for_each = { for app, slug in local.app_project_slugs : app => slug if !contains(var.imported_app_projects, app) }

  project_id = infisical_project.app[each.key].id
  name       = "Development"
  slug       = var.infisical_env
}
