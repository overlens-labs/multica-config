# Offline plans with a mocked provider (no backend, no encryption, no token).
# Run: tofu init -backend=false && tofu test

mock_provider "github" {}

variables {
  org        = "acme"
  aws_region = "us-east-1"
  github_org = "acme"
  agents = {
    pe-backend = { github = { installation_id = 42, repos = ["app", "ops"] } }
    tech-lead  = { github = { installation_id = 43, repos = ["app"] } }
    no-github  = {}
  }
}

run "one_resource_per_agent_repo" {
  command = plan

  assert {
    condition     = output.installation_repos == tolist(["pe-backend/app", "pe-backend/ops", "tech-lead/app"])
    error_message = "every agents.*.github.repos entry must become one installation repo"
  }

  assert {
    condition     = github_app_installation_repository.this["tech-lead/app"].installation_id == "43" && github_app_installation_repository.this["pe-backend/ops"].repository == "ops"
    error_message = "installation id and repo must come from the agent entry"
  }
}

run "offboarding_drops_repos" {
  command = plan

  variables {
    agents = {
      tech-lead = { github = { installation_id = 43, repos = ["app"] } }
    }
  }

  assert {
    condition     = output.installation_repos == tolist(["tech-lead/app"])
    error_message = "a removed agent's repos must leave the installation"
  }
}

# The main stack's agents map carries more fields (display_name, multica...);
# the conversion must drop them instead of failing.
run "accepts_full_agent_entries" {
  command = plan

  variables {
    agents = {
      pe-backend = {
        display_name = "PE Backend"
        aws          = true
        github       = { installation_id = 42, repos = ["app"], bot_user_id = 7 }
        multica      = { max_concurrent_tasks = 2, skills = ["x"] }
      }
    }
  }

  assert {
    condition     = output.installation_repos == tolist(["pe-backend/app"])
    error_message = "extra attributes must be ignored"
  }
}
