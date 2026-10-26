variable "slug" {
  description = "Agent slug (e.g. pe-backend)."
  type        = string
}

variable "display_name" {
  type = string
}

variable "infisical_org_id" {
  type = string
}

variable "infisical_env" {
  type = string
}

variable "org_role" {
  type = string
}

variable "universal_auth" {
  type = object({
    access_token_ttl     = number
    access_token_max_ttl = number
    trusted_ips          = list(string)
  })
}

variable "agents_credentials" {
  type = object({
    project_id   = string
    project_slug = string
    path_prefix  = string
    isolate      = bool
  })
}

variable "agents_credentials_ready" {
  description = "Base-module resources the agent folder depends on (environment/prefix folder)."
  type        = list(string)
  default     = []
}

variable "folder_exists" {
  description = "The agent folder was created by hand; don't manage it."
  type        = bool
  default     = false
}

variable "app_project_ids" {
  description = "Infisical <app>-dev projects the agent joins, app => project id."
  type        = map(string)
  default     = {}
}

variable "app_project_role" {
  type = string
}

variable "aws" {
  description = "null = the agent has no AWS access."
  type = object({
    account_id  = string
    region      = string
    role_arn    = string
    user_path   = string
    user_prefix = string
    role_name   = string
  })
  default = null
}

variable "github" {
  description = "null = no GitHub App wiring."
  type = object({
    app_slug        = string
    installation_id = number
    bot_user_id     = optional(number)
  })
  default = null
}
