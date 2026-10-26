# Adopts resources that were created by hand (runbook OVER-7) instead of
# recreating them. Everything is driven by var.imports, so an org starting
# from scratch leaves it empty and these blocks do nothing.
#
# Import blocks are idempotent: once a resource is in state, the block is a
# no-op, so the entries can stay in tfvars after the first apply.
#
# Not importable, handled elsewhere:
#   - Infisical project memberships: `adopt_existing = true` in the module.
#   - Infisical folders: `imports.agents.<agent>.folder_exists = true`.
#   - Universal Auth client secrets and AWS access keys: their values can't be
#     read back, so new ones are created and the old ones revoked by hand.

locals {
  import_aws_users = toset([for a, cfg in var.imports.agents : a if cfg.iam_user && try(var.agents[a].aws, false)])

  import_identities = { for a, cfg in var.imports.agents : a => cfg.infisical_identity_id if cfg.infisical_identity_id != null && contains(keys(var.agents), a) }

  import_agent_secrets = merge([
    for a, cfg in var.imports.agents : {
      for s in cfg.secrets : "${a}/${s}" => { agent = a, name = s }
    } if contains(keys(var.agents), a)
  ]...)

  import_repos = merge([
    for a, cfg in var.agents : {
      for r in cfg.github.repos : "${a}/${r}" => { agent = a, repo = r, installation_id = cfg.github.installation_id }
    } if cfg.github != null && contains(keys(var.imports.agents), a)
  ]...)

  agents_path_prefix = trimsuffix(var.agents_credentials.path_prefix, "/")
}

# --- Base ------------------------------------------------------------------

import {
  for_each = var.imports.agents_credentials_project_id == null ? toset([]) : toset([var.imports.agents_credentials_project_id])
  to       = module.base.infisical_project.agents_credentials
  id       = each.value
}

import {
  for_each = var.imports.app_infisical_project_ids
  to       = module.base.infisical_project.app[each.key]
  id       = each.value
}

import {
  for_each = { for app in var.imports.neon_roles : app => var.apps[app].neon }
  to       = module.base.neon_role.agents[each.key]
  id       = "${each.value.project_id}/${each.value.branch_id}/${each.value.role_name}"
}

import {
  for_each = var.imports.aws_base ? toset(["this"]) : toset([])
  to       = module.base.aws_iam_policy.access
  id       = "arn:aws:iam::${var.aws_account_id}:policy/${var.aws.policy_name}"
}

import {
  for_each = var.imports.aws_base ? toset(["this"]) : toset([])
  to       = module.base.aws_iam_role.agents
  id       = var.aws.role_name
}

import {
  for_each = var.imports.aws_base ? toset(["this"]) : toset([])
  to       = module.base.aws_iam_role_policy_attachment.access
  id       = "${var.aws.role_name}/arn:aws:iam::${var.aws_account_id}:policy/${var.aws.policy_name}"
}

# --- Agents ----------------------------------------------------------------

import {
  for_each = local.import_identities
  to       = module.agent[each.key].infisical_identity.this
  id       = each.value
}

import {
  for_each = local.import_identities
  to       = module.agent[each.key].infisical_identity_universal_auth.this
  id       = each.value
}

# Composite id <project>:<env>:<path>:<name>; only possible when the project
# id is known up front, i.e. agents-credentials is imported too.
import {
  for_each = var.imports.agents_credentials_project_id == null ? {} : local.import_agent_secrets
  to       = module.agent[each.value.agent].infisical_secret.this[each.value.name]
  id       = "${var.imports.agents_credentials_project_id}:${var.infisical_env}:${local.agents_path_prefix}/${each.value.agent}:${each.value.name}"
}

import {
  for_each = local.import_aws_users
  to       = module.agent[each.key].aws_iam_user.this[0]
  id       = "${var.aws.user_prefix}${each.key}"
}

import {
  for_each = local.import_aws_users
  to       = module.agent[each.key].aws_iam_user_policy.assume[0]
  id       = "${var.aws.user_prefix}${each.key}:assume-${var.aws.role_name}"
}

# Repos already selected on an adopted agent's installation.
import {
  for_each = local.import_repos
  to       = module.agent[each.value.agent].github_app_installation_repository.this[each.value.repo]
  id       = "${each.value.installation_id}:${each.value.repo}"
}
