output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  description = "URL base del API (https://<id>.execute-api.<región>.amazonaws.com)."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "upload_url" {
  description = "URL completa de la ruta de subida."
  value       = "${aws_apigatewayv2_api.this.api_endpoint}/upload"
}

output "access_log_group_name" {
  value = aws_cloudwatch_log_group.access.name
}
