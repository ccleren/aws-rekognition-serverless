output "distribution_id" {
  description = "ID de la distribución (invalidaciones de caché)."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "ARN de la distribución (condición AWS:SourceArn de las políticas de bucket)."
  value       = aws_cloudfront_distribution.this.arn
}

output "domain_name" {
  description = "Dominio <id>.cloudfront.net."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "site_url" {
  value = "https://${aws_cloudfront_distribution.this.domain_name}"
}
