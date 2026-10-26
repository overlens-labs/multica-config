module "base" {
  source = "./modules/base"

  org            = var.org
  aws_account_id = var.aws_account_id
  infisical_env  = var.infisical_env
  aws = {
    role_name              = var.aws.role_name
    policy_name            = var.aws.policy_name
    user_path              = var.aws.user_path
    user_prefix            = var.aws.user_prefix
    dev_bucket_pattern     = var.aws.dev_bucket_pattern
    denied_bucket_patterns = var.aws.denied_bucket_patterns
    cloudfront_dev_tag     = var.aws.cloudfront_dev_tag
    max_session_duration   = var.aws.max_session_duration
  }
  agents_credentials          = var.agents_credentials
  agents_credentials_imported = var.imports.agents_credentials_project_id != null
  apps                        = { for app, cfg in var.apps : app => { infisical_project_slug = cfg.infisical_project_slug, neon = cfg.neon } }
  imported_app_projects       = toset(keys(var.imports.app_infisical_project_ids))
}

locals {
  agent_imports = var.imports.agents
}

module "agent" {
  source   = "./modules/agent"
  for_each = var.agents

  slug             = each.key
  display_name     = each.value.display_name
  infisical_org_id = var.infisical_org_id
  infisical_env    = var.infisical_env
  org_role         = var.agent_org_role
  universal_auth   = var.universal_auth

  agents_credentials = {
    project_id   = module.base.agents_credentials_project_id
    project_slug = module.base.agents_credentials_project_slug
    path_prefix  = trimsuffix(var.agents_credentials.path_prefix, "/") == "" ? "/" : trimsuffix(var.agents_credentials.path_prefix, "/")
    isolate      = var.agents_credentials.isolate
  }
  agents_credentials_ready = module.base.agents_credentials_ready
  folder_exists            = try(local.agent_imports[each.key].folder_exists, false)

  app_project_ids  = { for app in each.value.apps : app => module.base.app_project_ids[app] }
  app_project_role = var.agent_project_role

  aws = !each.value.aws ? null : {
    account_id  = var.aws_account_id
    region      = var.aws_region
    role_arn    = module.base.role_arn
    user_path   = var.aws.user_path
    user_prefix = var.aws.user_prefix
    role_name   = var.aws.role_name
  }

  github = each.value.github == null ? null : {
    app_slug        = coalesce(each.value.github.app_slug, "${var.org}-${each.key}")
    installation_id = each.value.github.installation_id
    bot_user_id     = each.value.github.bot_user_id
  }
}
