# Módulo genérico para una Lambda de Python sin dependencias:
# zip con handler.py + rol propio (mínimo privilegio) + log group con retención.
# Los permisos de invocación (S3, SNS, API Gateway) los define quien la usa.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  log_group_name = "/aws/lambda/${var.function_name}"
  log_group_arn  = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}"
}

# --- Código ---------------------------------------------------------------------

data "archive_file" "this" {
  type        = "zip"
  source_file = var.source_file
  output_path = "${var.build_dir}/${var.function_name}.zip"

  # Permisos fijos para que el hash del zip sea igual en Windows, macOS y Linux.
  output_file_mode = "0644"
}

# --- Logs -----------------------------------------------------------------------
# Creado por Terraform (y no por Lambda en la primera ejecución) para fijar la
# retención y que terraform destroy lo elimine.

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

# --- IAM ------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.function_name
  description        = "Rol de ejecución de la Lambda ${var.function_name}."
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# El log group ya existe, así que basta con crear streams y escribir eventos,
# y solo en el grupo propio.
data "aws_iam_policy_document" "this" {
  source_policy_documents = [var.policy_json]

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "inline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

# --- Función --------------------------------------------------------------------

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = var.description
  role          = aws_iam_role.this.arn

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  handler          = var.handler
  runtime          = var.runtime
  architectures    = [var.architecture]

  memory_size                    = var.memory_size
  timeout                        = var.timeout
  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = var.environment
  }

  # Logs en JSON: los campos "extra" de logging salen como atributos consultables.
  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.this.name
    application_log_level = "INFO"
    system_log_level      = "WARN"
  }

  depends_on = [aws_iam_role_policy.this]
}
