# Unit plans of modules/agent with mocked providers.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
}
mock_provider "infisical" {}
mock_provider "github" {
  mock_data "github_user" {
    defaults = {
      id = "123456"
    }
  }
  mock_data "github_app" {
    defaults = {
      id = "777"
    }
  }
}

variables {
  slug             = "pe-backend"
  display_name     = "PE Backend"
  infisical_org_id = "org-id"
  infisical_env    = "dev"
  org_role         = "no-access"
  app_project_role = "member"
  universal_auth   = { access_token_ttl = 3600, access_token_max_ttl = 86400, trusted_ips = ["0.0.0.0/0"] }
  agents_credentials = {
    project_id   = "creds"
    project_slug = "agents-credentials"
    path_prefix  = "/"
    isolate      = false
  }
  app_project_ids = { billing = "billing-dev-id" }
  github          = { app_slug = "acme-pe-backend", installation_id = 42, repos = ["app", "ops"] }
  aws = {
    account_id  = "123456789012"
    region      = "us-east-1"
    role_arn    = "arn:aws:iam::123456789012:role/agents-dev"
    user_path   = "/agents/"
    user_prefix = "agent-"
    role_name   = "agents-dev"
  }
}

run "full_agent" {
  command = plan

  module {
    source = "./modules/agent"
  }

  assert {
    condition     = aws_iam_user.this[0].path == "/agents/" && aws_iam_user.this[0].name == "agent-pe-backend"
    error_message = "IAM user must live under /agents/ for the trust policy"
  }

  assert {
    condition     = aws_iam_user_policy.assume[0].name == "assume-agents-dev"
    error_message = "inline policy name"
  }

  assert {
    condition     = length(infisical_secret.this) == 11
    error_message = "6 GitHub + 5 AWS secrets expected"
  }

  assert {
    condition     = infisical_secret.this["GIT_AUTHOR_EMAIL"].value == "123456+acme-pe-backend[bot]@users.noreply.github.com"
    error_message = "commit e-mail must use the looked-up bot id"
  }

  assert {
    condition     = infisical_secret.this["GH_APP_ID"].value == "777" && infisical_secret.this["AWS_ROLE_SESSION_NAME"].value == "agent-pe-backend"
    error_message = "app id / session name"
  }

  assert {
    condition     = alltrue([for s in infisical_secret.this : s.folder_path == "/pe-backend" && s.env_slug == "dev"])
    error_message = "secrets must go to /<agent> in dev"
  }

  assert {
    condition     = infisical_identity.this.name == "agent-pe-backend" && infisical_identity.this.role == "no-access"
    error_message = "identity name/role"
  }

  assert {
    condition     = length(github_app_installation_repository.this) == 2 && length(infisical_project_identity.app) == 1
    error_message = "repos and app memberships"
  }

  assert {
    condition     = length(infisical_secret_folder.this) == 1 && infisical_secret_folder.this[0].folder_path == "/"
    error_message = "agent folder under the prefix"
  }

  assert {
    condition     = infisical_project_identity.agents_credentials.roles[0].role_slug == "member" && length(infisical_project_identity_specific_privilege.own_folder) == 0
    error_message = "no isolation by default"
  }
}

run "github_only_isolated_existing_folder" {
  command = plan

  module {
    source = "./modules/agent"
  }

  variables {
    aws           = null
    folder_exists = true
    github        = { app_slug = "acme-tech-lead", installation_id = 43, repos = ["app"], bot_user_id = 999 }
    agents_credentials = {
      project_id   = "creds"
      project_slug = "agents-credentials"
      path_prefix  = "/agents"
      isolate      = true
    }
  }

  assert {
    condition     = length(aws_iam_user.this) == 0 && length(infisical_secret.this) == 6
    error_message = "no AWS resources without aws"
  }

  assert {
    condition     = infisical_secret.this["GIT_COMMITTER_EMAIL"].value == "999+acme-tech-lead[bot]@users.noreply.github.com"
    error_message = "explicit bot id wins over the lookup"
  }

  assert {
    condition     = length(infisical_secret_folder.this) == 0
    error_message = "existing folder must not be managed"
  }

  assert {
    condition     = infisical_project_identity.agents_credentials.roles[0].role_slug == "no-access" && length(infisical_project_identity_specific_privilege.own_folder) == 1
    error_message = "isolation: no-access + own-folder privilege"
  }

  assert {
    condition     = strcontains(infisical_project_identity_specific_privilege.own_folder[0].permissions_v2[0].conditions, "/agents/pe-backend/**")
    error_message = "privilege must be scoped to the agent folder"
  }
}
