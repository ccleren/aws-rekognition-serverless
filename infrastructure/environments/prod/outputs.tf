output "site_url" {
  description = "URL pública de la aplicación."
  value       = local.site_origin
}

output "api_endpoint" {
  description = "URL base del API (la subida es POST <api_endpoint>/upload)."
  value       = module.api.api_endpoint
}

output "frontend_bucket" {
  description = "Bucket de la web (destino de aws s3 sync)."
  value       = module.storage.frontend_bucket_id
}

output "data_bucket" {
  description = "Bucket de datos (input/, output/, output-video/)."
  value       = module.storage.data_bucket_id
}

output "distribution_id" {
  description = "ID de la distribución de CloudFront (invalidaciones)."
  value       = module.cloudfront.distribution_id
}
