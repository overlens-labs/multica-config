# Example: the Overlens values. No secrets here — every credential comes from
# the admin's environment (see providers.tf). Copy to <org>.tfvars for a new
# org and replace every value.
#
# Values marked TODO are not known to the agent that wrote this file; fill
# them in before the first `tofu plan`.

org            = "overlens"
aws_account_id = "000000000000" # TODO: Overlens AWS account id
aws_region     = "sa-east-1"    # TODO: confirm the default region
github_org     = "overlens"

infisical_host   = "https://secrets.overlens.com.br"
infisical_org_id = "TODO-infisical-org-id"

aws = {
  dev_bucket_pattern = "dev-*-overlens"
}

agents_credentials = {
  # Today's layout is /<agent> (e.g. /pe-backend), not /agents/<agent>.
  path_prefix = "/"
  # Self-hosted without additional privileges: keep the shared `member` role.
  isolate = false
}

# The original runbook used `member` at org level; keep it until the first plan
# shows how the existing identities are configured.
agent_org_role = "member"

# No app is wired to the agents yet. Example shape:
# apps = {
#   billing = {
#     neon = {
#       project_id = "shiny-cell-12345678"
#       branch_id  = "br-dev-branch-id"
#       database   = "billing"
#     }
#     vercel  = { project_name = "billing-web" }
#     railway = { api = { project_id = "…", environment_id = "…" } }
#   }
# }
apps = {}

agents = {
  pe-backend = {
    display_name = "PE Backend"
    github = {
      installation_id = 0 # TODO: from the App's installation URL
      repos           = ["multica-config"]
    }
    multica = { max_concurrent_tasks = 2, skills = ["overlens-conventions"] }
  }
  pe-frontend = {
    display_name = "PE Frontend"
    github = {
      installation_id = 0 # TODO
      repos           = ["multica-config"]
    }
    multica = { max_concurrent_tasks = 2, skills = ["overlens-conventions"] }
  }
  tech-lead = {
    display_name = "Tech Lead"
    github = {
      installation_id = 0 # TODO
      repos           = ["multica-config"]
      bot_user_id     = 347949253
    }
    multica = { max_concurrent_tasks = 1, skills = ["overlens-conventions"] }
  }
  bibliotecario = {
    display_name = "Bibliotecário"
    github = {
      installation_id = 0 # TODO
      repos           = ["multica-config"]
    }
    multica = { max_concurrent_tasks = 1, skills = ["overlens-conventions"] }
  }
}

# What was created by hand (OVER-4 to OVER-7) and is adopted on the first apply.
imports = {
  agents_credentials_project_id = "ba198313-2f1c-4c66-b9b5-4bb36599308a"

  agents = {
    pe-backend = {
      infisical_identity_id = "TODO-identity-id"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
    pe-frontend = {
      infisical_identity_id = "TODO-identity-id"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
    tech-lead = {
      infisical_identity_id = "TODO-identity-id"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
    bibliotecario = {
      infisical_identity_id = "TODO-identity-id"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
  }
}
