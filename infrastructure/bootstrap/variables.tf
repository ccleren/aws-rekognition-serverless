variable "aws_region" {
  description = "Región donde se crean el bucket de estado y donde desplegará el entorno."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de nombres. Debe coincidir con project_name del entorno: los permisos del rol de despliegue se acotan a recursos con este prefijo."
  type        = string
  default     = "vision-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name: 3-32 caracteres, minúsculas, números y guiones (se usa en nombres de bucket)."
  }
}

variable "github_owner" {
  description = "Usuario u organización de GitHub propietario del repositorio."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.github_owner))
    error_message = "github_owner no es un nombre de usuario/organización de GitHub válido."
  }
}

variable "github_repo" {
  description = "Nombre del repositorio (sin el propietario)."
  type        = string
  default     = "aws-rekognition-serverless"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo no es un nombre de repositorio válido."
  }
}

variable "github_branch" {
  description = "Rama desde la que se permite asumir el rol (job de plan, sin entorno)."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "Entorno de GitHub (con aprobación manual) desde el que se permite asumir el rol (job de apply)."
  type        = string
  default     = "production"
}

variable "create_oidc_provider" {
  description = "Crear el proveedor OIDC de GitHub. Solo puede existir uno por cuenta: pon false si ya existe y se reutilizará."
  type        = bool
  default     = true
}

variable "state_bucket_force_destroy" {
  description = "Permitir que terraform destroy borre el bucket de estado aunque tenga objetos. Déjalo en false salvo para desmontar la cuenta de pruebas."
  type        = bool
  default     = false
}

variable "state_noncurrent_version_days" {
  description = "Días que se conservan las versiones antiguas del estado."
  type        = number
  default     = 90
}
