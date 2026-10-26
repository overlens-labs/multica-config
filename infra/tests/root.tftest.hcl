# Offline plans with mocked providers: the root config evaluates for a
# realistic input without touching any account (state encryption and the
# backend are not used by `tofu test`).
# Run: tofu init -backend=false && tofu test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/agents-dev-access"
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
}
# Neon is not exercised: mock_data can't fill the computed `endpoints` block
# of neon_branch_endpoints (OpenTofu limitation).
mock_provider "neon" {}

variables {
  org              = "acme"
  aws_account_id   = "123456789012"
  aws_region       = "us-east-1"
  github_org       = "acme"
  infisical_host   = "https://secrets.example.com"
  infisical_org_id = "org-id"
  aws              = { dev_bucket_pattern = "dev-*-acme" }

  apps = {
    billing = {
      vercel  = { project_name = "billing-web" }
      railway = { api-server = { project_id = "rp", environment_id = "re" } }
    }
  }

  agents = {
    pe-backend = {
      display_name = "PE Backend"
      apps         = ["billing"]
      aws          = true
      railway      = ["billing/api-server"]
      github       = { installation_id = 42, repos = ["app", "ops"] }
      multica      = { max_concurrent_tasks = 2, skills = ["acme-conventions"] }
    }
    tech-lead = {
      display_name = "Tech Lead"
      github       = { installation_id = 43, repos = ["app"], bot_user_id = 999 }
    }
  }
}

run "onboarding" {
  command = plan

  assert {
    condition     = output.multica_agents["pe-backend"].secret_path == "/pe-backend"
    error_message = "secret path should be /<agent> with the default prefix"
  }

  assert {
    condition     = output.multica_agents["pe-backend"].max_concurrent_tasks == 2 && output.multica_agents["tech-lead"].max_concurrent_tasks == 1
    error_message = "concurrency must come from the map (default 1)"
  }

  assert {
    condition     = keys(output.multica_agents["pe-backend"].app_project_ids) == ["billing"]
    error_message = "app memberships must follow agents.*.apps"
  }

  assert {
    condition     = output.railway_tokens[0].key == "BILLING_API_SERVER" && output.railway_tokens[0].agent == "pe-backend" && length(output.railway_tokens) == 1
    error_message = "railway token plan is wrong"
  }

  assert {
    condition     = output.vercel_sync_checklist["billing"].vercel_project == "billing-web"
    error_message = "vercel checklist is wrong"
  }
}

run "nested_prefix" {
  command = plan

  variables {
    agents_credentials = { path_prefix = "/agents/" }
  }

  assert {
    condition     = output.multica_agents["pe-backend"].secret_path == "/agents/pe-backend"
    error_message = "nested prefix not applied"
  }
}

run "offboarding" {
  command = plan

  variables {
    agents = {
      tech-lead = {
        display_name = "Tech Lead"
        github       = { installation_id = 43, repos = ["app"], bot_user_id = 999 }
      }
    }
  }

  assert {
    condition     = keys(output.multica_agents) == ["tech-lead"]
    error_message = "a removed agent must disappear"
  }
}

# Import blocks can't run under `tofu test` (mock providers can't import);
# they are checked with `tofu console` against overlens.tfvars (see README).

run "rejects_unknown_app" {
  command = plan

  variables {
    agents = {
      x-agent = { display_name = "X", apps = ["nope"] }
    }
  }

  expect_failures = [var.agents]
}

run "railway_same_service_in_two_apps" {
  command = plan

  variables {
    apps = {
      billing = { railway = { api = { project_id = "p1", environment_id = "e1" } } }
      crm     = { railway = { api = { project_id = "p2", environment_id = "e2" } } }
    }
    agents = {
      pe-backend = {
        display_name = "PE Backend"
        railway      = ["billing/api", "crm/api"]
      }
    }
  }

  assert {
    condition     = toset([for t in output.railway_tokens : t.key]) == toset(["BILLING_API", "CRM_API"])
    error_message = "tokens of the same service in two apps must not collide"
  }

  assert {
    condition     = toset([for t in output.railway_tokens : t.project_id]) == toset(["p1", "p2"])
    error_message = "each token must keep its own project"
  }
}

run "rejects_colliding_railway_names" {
  command = plan

  variables {
    apps = {
      a-b = { railway = { c = { project_id = "p1", environment_id = "e1" } } }
      a   = { railway = { b-c = { project_id = "p2", environment_id = "e2" } } }
    }
    agents = {
      pe-backend = {
        display_name = "PE Backend"
        railway      = ["a-b/c", "a/b-c"]
      }
    }
  }

  expect_failures = [var.agents]
}

run "rejects_admin_role" {
  command = plan

  variables {
    agent_project_role = "admin"
  }

  expect_failures = [var.agent_project_role]
}
