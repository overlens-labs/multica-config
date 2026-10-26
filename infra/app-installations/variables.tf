# Reads the same <org>.tfvars as the main stack (`-var-file=../<org>.tfvars`),
# so `agents.<agent>.github.repos` keeps a single home. Variables that only the
# main stack uses produce a "Value for undeclared variable" warning; extra
# attributes of the objects below are dropped by the type conversion.

variable "org" {
  description = "Short org slug; names the state bucket and KMS alias."
  type        = string
}

variable "aws_region" {
  description = "Region of the state bucket and KMS key."
  type        = string
}

variable "github_org" {
  description = "GitHub organization that owns the repos."
  type        = string
}

variable "agents" {
  description = "The main stack's agents map; only github.installation_id/repos are read here."
  type = map(object({
    github = optional(object({
      installation_id = number
      repos           = list(string)
    }))
  }))
  default = {}
}

variable "adopt_existing" {
  description = <<-EOT
    Import every configured repo instead of adding it. Use once, when moving
    the installations from the main state (they are already selected on the
    App), with `-var adopt_existing=true`. Leave false afterwards: importing a
    repo that isn't on the installation yet fails.
  EOT
  type        = bool
  default     = false
}
