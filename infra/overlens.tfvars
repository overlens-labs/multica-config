# Example: the Overlens values. No secrets here — every credential comes from
# the admin's environment (see providers.tf). Copy to <org>.tfvars for a new
# org and replace every value.
#
# Values marked TODO are not known to the agent that wrote this file; fill
# them in before the first `tofu plan`.

org            = "overlens"
aws_account_id = "437341204924"
aws_region     = "sa-east-1"
github_org     = "overlens"

infisical_host   = "https://secrets.overlens.com.br"
infisical_org_id = "cab0c8c3-80c9-4a9d-a381-8281d46eefdf"

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
      installation_id = 175214890
      repos           = ["multica-config"]
    }
    multica = { max_concurrent_tasks = 2, skills = ["overlens-conventions"] }
  }
  pe-frontend = {
    display_name = "PE Frontend"
    github = {
      installation_id = 175214920
      repos           = ["multica-config"]
    }
    multica = { max_concurrent_tasks = 2, skills = ["overlens-conventions"] }
  }
  tech-lead = {
    display_name = "Tech Lead"
    github = {
      installation_id = 0 175214968
      repos           = ["multica-config"]
      bot_user_id     = 347949253
    }
    multica = { max_concurrent_tasks = 1, skills = ["overlens-conventions"] }
  }
  bibliotecario = {
    display_name = "Bibliotecário"
    github = {
      installation_id = 175214708
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
      infisical_identity_id = "2d814652-0fe8-4d06-82ff-5e1c249fc370"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
    pe-frontend = {
      infisical_identity_id = "da1a9e87-caa6-4ff0-ab4e-52d102bd4d6d"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
    tech-lead = {
      infisical_identity_id = "0262b704-3771-4473-9190-5f319bd89480"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
    bibliotecario = {
      infisical_identity_id = "c6c31b57-ee67-42da-9dc4-e917d1ca2278"
      folder_exists         = true
      secrets               = ["GH_APP_ID", "GH_APP_INSTALLATION_ID", "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"]
    }
  }
}
