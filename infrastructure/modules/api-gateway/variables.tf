variable "name" {
  description = "Nombre del API (p. ej. <project_name>-api). También se usa para el log group de access logs."
  type        = string
}

variable "lambda_function_name" {
  description = "Nombre de la Lambda Upload."
  type        = string
}

variable "lambda_invoke_arn" {
  description = "ARN de invocación de la Lambda Upload."
  type        = string
}

variable "allowed_origins" {
  description = "Orígenes permitidos por CORS (https://<dominio>, sin barra final)."
  type        = list(string)

  validation {
    condition     = alltrue([for origin in var.allowed_origins : can(regex("^https?://[^/]+$", origin))])
    error_message = "Cada origen debe tener la forma esquema://host[:puerto], sin ruta ni barra final."
  }
}

variable "throttle_rate" {
  description = "Peticiones por segundo sostenidas en el stage."
  type        = number
  default     = 5
}

variable "throttle_burst" {
  description = "Ráfaga máxima de peticiones en el stage."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "Días de retención de los access logs."
  type        = number
  default     = 14
}
