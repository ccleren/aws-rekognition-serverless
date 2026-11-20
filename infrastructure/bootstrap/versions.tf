terraform {
  # 1.10 es la primera versión con bloqueo nativo de estado en S3 (use_lockfile).
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Sin bloque backend: el estado del bootstrap es local (este módulo crea el backend
  # remoto que usa el resto). terraform.tfstate está en .gitignore.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Component = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
