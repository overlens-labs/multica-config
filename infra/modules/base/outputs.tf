output "role_arn" {
  value = aws_iam_role.agents.arn
}

output "agents_credentials_project_id" {
  value = infisical_project.agents_credentials.id
}

output "agents_credentials_project_slug" {
  value = infisical_project.agents_credentials.slug
}

output "app_project_ids" {
  value = { for app, p in infisical_project.app : app => p.id }
}

# Exposed so agent folders are created after the prefix folder/environment.
output "agents_credentials_ready" {
  value = concat(
    [for e in infisical_project_environment.agents_credentials : e.id],
    [for f in infisical_secret_folder.agents_prefix : f.id],
  )
}
