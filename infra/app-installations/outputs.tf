output "installation_repos" {
  description = "agent/repo pairs selected on the agents' App installations."
  value       = sort(keys(local.installation_repos))
}
