variable "name_prefix" {
  description = "Prefijo de nombres (project_name). OAC y políticas tienen nombres únicos por cuenta."
  type        = string
}

variable "frontend_bucket_id" {
  description = "Nombre del bucket de la web."
  type        = string
}

variable "frontend_bucket_regional_domain_name" {
  description = "Dominio regional del bucket de la web."
  type        = string
}

variable "data_bucket_id" {
  description = "Nombre del bucket de datos."
  type        = string
}

variable "data_bucket_regional_domain_name" {
  description = "Dominio regional del bucket de datos."
  type        = string
}

variable "csp_connect_src" {
  description = "Orígenes adicionales permitidos en connect-src de la CSP (el API de subida)."
  type        = list(string)
}

variable "extra_allowed_origins" {
  description = "Orígenes extra (desarrollo local) a los que se permite leer los resultados por CORS."
  type        = list(string)
  default     = []
}

variable "price_class" {
  description = "Clase de precio de CloudFront."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class debe ser PriceClass_100, PriceClass_200 o PriceClass_All."
  }
}
