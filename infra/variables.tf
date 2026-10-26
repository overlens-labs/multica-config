# ---------------------------------------------------------------------------
# Organization
# ---------------------------------------------------------------------------

variable "org" {
  description = "Short org slug (lowercase). Names the state bucket/KMS alias and the default GitHub App slugs."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.org))
    error_message = "org must be a lowercase slug."
  }
}

variable "aws_account_id" {
  description = "AWS account that holds the agents-dev role. The provider refuses any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must have 12 digits."
  }
}

variable "aws_region" {
  description = "AWS region for the state bucket, KMS key and the agents' default region."
  type        = string
}

variable "github_org" {
  description = "GitHub organization that owns the repos and the per-agent Apps."
  type        = string
}

variable "infisical_host" {
  description = "Infisical base URL, without /api (e.g. https://secrets.example.com)."
  type        = string
}

variable "infisical_org_id" {
  description = "Infisical organization ID (not secret)."
  type        = string
}

variable "infisical_env" {
  description = "The only Infisical environment agents get access to."
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------
# AWS access model (runbook §6)
# ---------------------------------------------------------------------------

variable "aws" {
  description = "Naming and resource patterns for the shared agents-dev role."
  type = object({
    role_name              = optional(string, "agents-dev")
    policy_name            = optional(string, "agents-dev-access")
    user_path              = optional(string, "/agents/")
    user_prefix            = optional(string, "agent-")
    dev_bucket_pattern     = string
    denied_bucket_patterns = optional(list(string), ["prod-*", "stage-*"])
    cloudfront_dev_tag = optional(object({
      key   = string
      value = string
    }), { key = "env", value = "dev" })
    max_session_duration = optional(number, 3600)
  })
}

# ---------------------------------------------------------------------------
# Infisical layout
# ---------------------------------------------------------------------------

variable "agents_credentials" {
  description = "Infisical project that holds one folder per agent with its tool credentials."
  type = object({
    name = optional(string, "agents-credentials")
    slug = optional(string, "agents-credentials")
    # Parent of the per-agent folders: "/" gives /<agent>, "/agents" gives /agents/<agent>.
    path_prefix = optional(string, "/")
    # true: agents are `no-access` members and get read only on their own
    # folder via an identity-specific privilege. Needs a plan/edition with
    # additional privileges; false keeps plain `member` (agents can read each
    # other's folders — see README, "Isolamento").
    isolate = optional(bool, false)
  })
  default = {}

  validation {
    condition     = startswith(var.agents_credentials.path_prefix, "/")
    error_message = "agents_credentials.path_prefix must start with /."
  }
}

variable "agent_project_role" {
  description = "Infisical project role given to agents in <app>-dev projects. Never admin."
  type        = string
  default     = "member"

  validation {
    condition     = var.agent_project_role != "admin"
    error_message = "Agents never get the admin role."
  }
}

variable "agent_org_role" {
  description = "Organization-level role of the agents' machine identities. Project access is granted per project."
  type        = string
  default     = "no-access"

  validation {
    condition     = var.agent_org_role != "admin"
    error_message = "Agents never get the admin role."
  }
}

variable "universal_auth" {
  description = "Universal Auth settings for the agents' machine identities (runbook §1)."
  type = object({
    access_token_ttl     = optional(number, 3600)
    access_token_max_ttl = optional(number, 86400)
    trusted_ips          = optional(list(string), ["0.0.0.0/0"])
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Apps in the agents' flow
# ---------------------------------------------------------------------------

variable "apps" {
  description = <<-EOT
    Apps in the agents' flow, keyed by app slug. Each app gets an Infisical
    project <app>-dev (dev environment only) and, optionally, a Neon role
    `agents_dev` on its dev branch whose connection string goes to that project.
    Vercel and Railway entries are read by the scripts and the README (no provider coverage).
  EOT
  type = map(object({
    infisical_project_slug = optional(string) # default "<app>-dev"
    neon = optional(object({
      project_id = string
      branch_id  = string # the `dev` branch id (br-...), never main/prod
      database   = string
      role_name  = optional(string, "agents_dev")
    }))
    vercel = optional(object({
      project_name = string
    }))
    railway = optional(map(object({
      project_id     = string
      environment_id = string # the `dev` environment
    })), {})
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Agents — onboarding = add an entry, offboarding = remove it
# ---------------------------------------------------------------------------

variable "agents" {
  description = "Agents keyed by slug (lowercase, hyphenated). See README for each field."
  type = map(object({
    display_name = string
    apps         = optional(list(string), []) # Infisical <app>-dev memberships
    aws          = optional(bool, false)
    railway      = optional(list(string), []) # "<app>/<railway key>" entries from var.apps
    github = optional(object({
      app_slug        = optional(string) # default "<org>-<agent>"
      installation_id = number
      repos           = list(string)
      bot_user_id     = optional(number) # default: looked up from "<app_slug>[bot]"
    }))
    multica = optional(object({
      max_concurrent_tasks = optional(number, 1)
      skills               = optional(list(string), [])
    }), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.agents) : can(regex("^[a-z][a-z0-9-]{1,40}$", k))])
    error_message = "Agent keys must be lowercase slugs (e.g. pe-backend)."
  }

  validation {
    condition     = alltrue(flatten([for a in values(var.agents) : [for app in a.apps : contains(keys(var.apps), app)]]))
    error_message = "Every agents.*.apps entry must be a key of var.apps."
  }

  validation {
    condition = alltrue(flatten([for a in values(var.agents) : [
      for r in a.railway : can(var.apps[split("/", r)[0]].railway[split("/", r)[1]])
    ]]))
    error_message = "Every agents.*.railway entry must be \"<app>/<key>\" of a var.apps.*.railway entry."
  }

  # Secret names are RAILWAY_TOKEN_<APP>_<KEY> with non-alphanumerics folded
  # to "_"; two entries that fold to the same name would overwrite each other.
  validation {
    condition = alltrue([for a in values(var.agents) :
      length(distinct([for r in a.railway : upper(replace(r, "/[^A-Za-z0-9]+/", "_"))])) == length(a.railway)
    ])
    error_message = "agents.*.railway entries must map to distinct RAILWAY_TOKEN_<APP>_<KEY> names (e.g. \"a-b/c\" and \"a/b-c\" collide)."
  }
}

# ---------------------------------------------------------------------------
# Resources created by hand before this code existed
# ---------------------------------------------------------------------------

variable "imports" {
  description = "IDs of pre-existing resources to adopt with `import` blocks instead of recreating. See imports.tf."
  type = object({
    agents_credentials_project_id = optional(string)
    app_infisical_project_ids     = optional(map(string), {})  # app => project id
    neon_roles                    = optional(list(string), []) # apps whose agents_dev role exists
    aws_base                      = optional(bool, false)      # role + policy + attachment exist
    agents = optional(map(object({
      infisical_identity_id = optional(string)
      # Secrets already in /<agent> that this code manages (e.g. GIT_AUTHOR_NAME).
      secrets  = optional(list(string), [])
      iam_user = optional(bool, false) # user + inline policy exist (the access key is never imported)
      # The /<agent> folder exists. Folders can't be imported, so the module
      # stops managing it (offboarding then leaves the empty folder behind).
      folder_exists = optional(bool, false)
    })), {})
  })
  default = {}
}
