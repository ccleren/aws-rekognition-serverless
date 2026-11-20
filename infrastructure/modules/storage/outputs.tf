output "frontend_bucket_id" {
  description = "Nombre del bucket de la web."
  value       = aws_s3_bucket.this["frontend"].id
}

output "frontend_bucket_arn" {
  value = aws_s3_bucket.this["frontend"].arn
}

output "frontend_bucket_regional_domain_name" {
  description = "Dominio regional del bucket (origen de CloudFront con OAC)."
  value       = aws_s3_bucket.this["frontend"].bucket_regional_domain_name
}

output "data_bucket_id" {
  description = "Nombre del bucket de datos."
  value       = aws_s3_bucket.this["data"].id
}

output "data_bucket_arn" {
  value = aws_s3_bucket.this["data"].arn
}

output "data_bucket_regional_domain_name" {
  description = "Dominio regional del bucket (origen de CloudFront con OAC)."
  value       = aws_s3_bucket.this["data"].bucket_regional_domain_name
}
