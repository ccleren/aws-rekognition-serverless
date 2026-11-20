output "state_bucket" {
  description = "Bucket del estado remoto. Valor de la variable de GitHub TF_STATE_BUCKET y de terraform init -backend-config=\"bucket=...\"."
  value       = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  description = "Rol que asume GitHub Actions. Valor de la variable de GitHub AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "Proveedor OIDC de GitHub (creado o reutilizado)."
  value       = local.oidc_provider_arn
}

output "aws_region" {
  description = "Región. Valor de la variable de GitHub AWS_REGION."
  value       = var.aws_region
}
