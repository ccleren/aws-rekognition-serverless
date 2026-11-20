# Ninguna variable es sensible: el proyecto no tiene secretos de aplicación.

variable "aws_region" {
  description = "Región de despliegue. Debe tener Rekognition Video (p. ej. us-east-1, eu-west-1)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de nombres de recursos. Debe coincidir con el del bootstrap (los permisos del rol de despliegue dependen de él)."
  type        = string
  default     = "vision-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name: 3-32 caracteres, minúsculas, números y guiones (se usa en nombres de bucket)."
  }
}

variable "app_name" {
  description = "Nombre visible de la aplicación (cabecera, título y PDF). Único sitio donde se cambia."
  type        = string
  default     = "Vision Lab"
}

# --- Subida y análisis ---------------------------------------------------------------

variable "max_upload_bytes" {
  description = "Tamaño máximo de archivo. Lo aplican la Lambda Upload y el frontend."
  type        = number
  default     = 4194304 # 4 MiB

  validation {
    # HTTP API → Lambda síncrona admite 6 MB de payload; en base64 el techo real es ≈ 4,5 MB.
    condition     = var.max_upload_bytes > 0 && var.max_upload_bytes <= 4500000
    error_message = "max_upload_bytes debe estar entre 1 y 4500000 (límite práctico de Lambda síncrona con base64)."
  }
}

variable "min_confidence" {
  description = "Confianza mínima (%) de las etiquetas que devuelve Rekognition."
  type        = number
  default     = 75

  validation {
    condition     = var.min_confidence >= 0 && var.min_confidence <= 100
    error_message = "min_confidence debe estar entre 0 y 100."
  }
}

variable "max_labels" {
  description = "Número máximo de etiquetas por imagen (DetectLabels). Con 10, en fotos de exterior las etiquetas de escena al 100 % desplazan a los objetos con caja."
  type        = number
  default     = 25

  validation {
    condition     = var.max_labels >= 1 && var.max_labels <= 1000
    error_message = "max_labels debe estar entre 1 y 1000."
  }
}

variable "process_reserved_concurrency" {
  description = "Concurrencia reservada para Process. null = sin reserva (las cuentas nuevas pueden rechazarla por cuota baja)."
  type        = number
  default     = null
}

# --- Frontend (polling) -------------------------------------------------------------------

variable "poll_image_timeout_seconds" {
  description = "Tiempo máximo que el frontend espera el resultado de una imagen."
  type        = number
  default     = 60
}

variable "poll_video_timeout_seconds" {
  description = "Tiempo máximo que el frontend espera el resultado de un vídeo antes de ofrecer seguir esperando. En pruebas reales, la cola de Rekognition Video tardó de 3,5 a 8 min."
  type        = number
  default     = 900
}

# --- Retención y coste --------------------------------------------------------------------

variable "data_retention_days" {
  description = "Días hasta que expiran input/ y los resultados (mínimo de S3: 1)."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Días de retención de los logs de CloudWatch."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days debe ser un valor admitido por CloudWatch Logs (1, 3, 5, 7, 14, 30, 60, 90...)."
  }
}

variable "api_throttle_rate" {
  description = "Peticiones por segundo sostenidas en el API."
  type        = number
  default     = 5
}

variable "api_throttle_burst" {
  description = "Ráfaga máxima de peticiones en el API."
  type        = number
  default     = 10
}

variable "price_class" {
  description = "Clase de precio de CloudFront."
  type        = string
  default     = "PriceClass_100"
}

variable "force_destroy" {
  description = "Permitir que terraform destroy borre los buckets con objetos. Desactívalo con datos reales."
  type        = bool
  default     = true
}

# --- Desarrollo local -----------------------------------------------------------------------

variable "extra_allowed_origins" {
  description = "Orígenes extra para CORS del API y de los resultados (p. ej. [\"http://localhost:8080\"])."
  type        = list(string)
  default     = []
}
