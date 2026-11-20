variable "name_prefix" {
  description = "Prefijo de nombres (project_name)."
  type        = string
}

variable "subscriber_function_name" {
  description = "Nombre de la Lambda que recibe la finalización de los análisis (Video Result)."
  type        = string
}

variable "subscriber_function_arn" {
  description = "ARN de la Lambda que recibe la finalización de los análisis (Video Result)."
  type        = string
}
