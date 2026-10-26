output "identity_id" {
  value = infisical_identity.this.id
}

output "client_id" {
  value = infisical_identity_universal_auth_client_secret.this.client_id
}

output "client_secret" {
  value     = infisical_identity_universal_auth_client_secret.this.client_secret
  sensitive = true
}

output "secret_path" {
  value = local.secret_path
}

output "iam_user_arn" {
  value = try(aws_iam_user.this[0].arn, null)
}
