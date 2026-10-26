# Read by scripts/sync-multica.sh and scripts/railway-tokens.sh.
# Only `agent_client_secrets` carries a secret, and it is `sensitive`.

output "infisical_host" {
  value = var.infisical_host
}

output "agents_credentials_project_id" {
  value = module.base.agents_credentials_project_id
}

output "app_project_ids" {
  value = module.base.app_project_ids
}

output "agents_dev_role_arn" {
  value = module.base.role_arn
}

output "multica_agents" {
  description = "Per-agent data for the Multica side (no secrets)."
  value = {
    for slug, a in var.agents : slug => {
      name                 = a.display_name
      client_id            = module.agent[slug].client_id
      infisical_project_id = module.base.agents_credentials_project_id
      secret_path          = module.agent[slug].secret_path
      env                  = var.infisical_env
      app_project_ids      = { for app in a.apps : app => module.base.app_project_ids[app] }
      max_concurrent_tasks = a.multica.max_concurrent_tasks
      skills               = a.multica.skills
      iam_user_arn         = module.agent[slug].iam_user_arn
    }
  }
}

output "agent_client_secrets" {
  description = "Universal Auth client secret per agent. Only sync-multica.sh reads it."
  value       = { for slug, m in module.agent : slug => m.client_secret }
  sensitive   = true
}

output "railway_tokens" {
  description = "Railway project tokens to create (no provider support; see scripts/railway-tokens.sh)."
  value = flatten([
    for slug, a in var.agents : [
      for r in a.railway : {
        agent                = slug
        key                  = upper(replace(split("/", r)[1], "-", "_"))
        project_id           = var.apps[split("/", r)[0]].railway[split("/", r)[1]].project_id
        environment_id       = var.apps[split("/", r)[0]].railway[split("/", r)[1]].environment_id
        infisical_project_id = module.base.agents_credentials_project_id
        secret_path          = module.agent[slug].secret_path
      }
    ]
  ])
}

output "vercel_sync_checklist" {
  description = "Infisical -> Vercel syncs to configure by hand (Preview/Development only)."
  value = {
    for app, cfg in var.apps : app => {
      infisical_project = module.base.app_project_ids[app]
      vercel_project    = cfg.vercel.project_name
    } if cfg.vercel != null
  }
}
