variable "function_name" {
  description = "Nombre de la función. También se usa para el rol de IAM y el log group."
  type        = string
}

variable "description" {
  description = "Descripción de la función."
  type        = string
  default     = ""
}

variable "source_file" {
  description = "Ruta al handler.py. Se empaqueta solo en la raíz del zip."
  type        = string
}

variable "build_dir" {
  description = "Directorio donde se escribe el zip (ignorado por Git)."
  type        = string
}

variable "handler" {
  description = "Punto de entrada <módulo>.<función>."
  type        = string
  default     = "handler.handler"
}

variable "runtime" {
  description = "Runtime de Lambda."
  type        = string
  default     = "python3.12"
}

variable "architecture" {
  description = "Arquitectura de la función (arm64 es más barata y el código es Python puro)."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture debe ser arm64 o x86_64."
  }
}

variable "memory_size" {
  description = "Memoria en MB."
  type        = number
  default     = 256
}

variable "timeout" {
  description = "Tiempo máximo de ejecución en segundos."
  type        = number
}

variable "environment" {
  description = "Variables de entorno de la función."
  type        = map(string)
  default     = {}
}

variable "policy_json" {
  description = "Política de IAM (JSON) con los permisos propios de la función. Los permisos de logs se añaden en el módulo."
  type        = string
}

variable "log_retention_days" {
  description = "Días de retención del log group."
  type        = number
  default     = 14
}

variable "reserved_concurrency" {
  description = "Concurrencia reservada. null = sin reserva (usa la cuota sin reservar de la cuenta)."
  type        = number
  default     = null
}
