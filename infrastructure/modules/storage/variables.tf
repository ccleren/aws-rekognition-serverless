variable "frontend_bucket_name" {
  description = "Nombre del bucket de la web. Se calcula en el entorno para poder usarlo en políticas antes de crear el bucket."
  type        = string
}

variable "data_bucket_name" {
  description = "Nombre del bucket de datos (input/, output/, output-video/)."
  type        = string
}

variable "cloudfront_distribution_arn" {
  description = "ARN de la distribución de CloudFront: la única que puede leer los buckets (OAC)."
  type        = string
}

variable "data_retention_days" {
  description = "Días hasta que expiran los objetos de input/, output/ y output-video/."
  type        = number
  default     = 1

  validation {
    condition     = var.data_retention_days >= 1
    error_message = "S3 no admite expiraciones de menos de 1 día."
  }
}

variable "force_destroy" {
  description = "Permitir que terraform destroy borre los buckets con objetos. Desactívalo si guardas datos reales."
  type        = bool
  default     = true
}
