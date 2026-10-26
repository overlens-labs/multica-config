# The App itself is created by hand (manifest flow, no API/provider); here we
# only pick the repos it is installed on and derive the commit identity.

data "github_app" "this" {
  count = var.github == null ? 0 : 1

  slug = var.github.app_slug
}

data "github_user" "bot" {
  count = var.github != null && try(var.github.bot_user_id, null) == null ? 1 : 0

  username = "${var.github.app_slug}[bot]"
}

locals {
  bot_login   = var.github == null ? "" : "${var.github.app_slug}[bot]"
  bot_user_id = var.github == null ? "" : coalesce(try(tostring(var.github.bot_user_id), null), try(data.github_user.bot[0].id, null))
  bot_email   = var.github == null ? "" : "${local.bot_user_id}+${local.bot_login}@users.noreply.github.com"
}

resource "github_app_installation_repository" "this" {
  for_each = var.github == null ? toset([]) : toset(var.github.repos)

  installation_id = tostring(var.github.installation_id)
  repository      = each.value
}
