variable "org" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "infisical_env" {
  type = string
}

variable "aws" {
  description = "See var.aws in the root module."
  type = object({
    role_name              = string
    policy_name            = string
    user_path              = string
    user_prefix            = string
    dev_bucket_pattern     = string
    denied_bucket_patterns = list(string)
    cloudfront_dev_tag = object({
      key   = string
      value = string
    })
    max_session_duration = number
  })
}

variable "agents_credentials" {
  type = object({
    name        = string
    slug        = string
    path_prefix = string
    isolate     = bool
  })
}

variable "agents_credentials_imported" {
  description = "The agents-credentials project already exists (its environments are left alone)."
  type        = bool
  default     = false
}

variable "apps" {
  description = "See var.apps in the root module."
  type = map(object({
    infisical_project_slug = optional(string)
    neon = optional(object({
      project_id = string
      branch_id  = string
      database   = string
      role_name  = optional(string, "agents_dev")
    }))
  }))
}

variable "imported_app_projects" {
  description = "Apps whose <app>-dev Infisical project already exists."
  type        = set(string)
  default     = []
}
