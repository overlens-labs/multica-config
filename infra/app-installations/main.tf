# Repos each agent's GitHub App is installed on. Kept out of the pipeline:
# adding repos to an installation needs an org owner's user token (an App
# token is rejected), so this root module is applied locally by the owner.
# See infra/README.md, "Pipeline".
#
# Credentials (environment only): GITHUB_TOKEN of an org owner; AWS access
# to the state bucket and KMS key (same as the main stack's admin).

provider "github" {
  owner = var.github_org
}

locals {
  installation_repos = merge([
    for agent, cfg in var.agents : {
      for repo in cfg.github.repos : "${agent}/${repo}" => {
        installation_id = cfg.github.installation_id
        repo            = repo
      }
    } if cfg.github != null
  ]...)
}

resource "github_app_installation_repository" "this" {
  for_each = local.installation_repos

  installation_id = tostring(each.value.installation_id)
  repository      = each.value.repo
}

import {
  for_each = var.adopt_existing ? local.installation_repos : {}
  to       = github_app_installation_repository.this[each.key]
  id       = "${each.value.installation_id}:${each.value.repo}"
}
