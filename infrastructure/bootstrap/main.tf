data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  prefix     = var.project_name

  github_oidc_url = "https://token.actions.githubusercontent.com"
  oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )

  deploy_role_name = "${local.prefix}-github-deploy"
  deploy_role_arn  = "arn:${local.partition}:iam::${local.account_id}:role/${local.deploy_role_name}"
}

# -----------------------------------------------------------------------------
# Bucket de estado de Terraform
# Versionado (recuperar estados anteriores), cifrado, privado y solo por TLS.
# El bloqueo es nativo de S3 (use_lockfile): no hace falta tabla de DynamoDB.
# -----------------------------------------------------------------------------

resource "random_id" "state_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "state" {
  bucket        = "${local.prefix}-tfstate-${random_id.state_suffix.hex}"
  force_destroy = var.state_bucket_force_destroy
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_version_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# Proveedor OIDC de GitHub (uno por cuenta)
# AWS valida los tokens de GitHub con su propia CA de confianza, así que no hace
# falta fijar thumbprints.
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = local.github_oidc_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = local.github_oidc_url
}

# -----------------------------------------------------------------------------
# Rol de despliegue que asume GitHub Actions
# Confianza limitada a este repositorio y, dentro de él, a la rama principal
# (job de plan) y al entorno con aprobación manual (job de apply). Los pull
# requests no pueden asumirlo: el CI no necesita AWS.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}",
        "repo:${var.github_owner}/${var.github_repo}:environment:${var.github_environment}",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.deploy_role_name
  description          = "Rol que asume GitHub Actions (OIDC) para desplegar ${var.project_name}."
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

# Permisos de despliegue: amplios por servicio, pero acotados a recursos con el
# prefijo del proyecto siempre que el servicio lo permite. Ver el README para
# los límites de este enfoque y cómo endurecerlo.
data "aws_iam_policy_document" "deploy" {
  # --- Estado de Terraform ---------------------------------------------------
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  # El rol puede gestionar buckets con el prefijo del proyecto, pero no tocar
  # la configuración ni la existencia del bucket de estado.
  statement {
    sid    = "ProtectStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  # --- S3: buckets frontend y data ---------------------------------------------
  statement {
    sid     = "ProjectBuckets"
    actions = ["s3:*"]
    resources = [
      "arn:${local.partition}:s3:::${local.prefix}-*",
      "arn:${local.partition}:s3:::${local.prefix}-*/*",
    ]
  }

  # --- Lambda ------------------------------------------------------------------
  statement {
    sid       = "ProjectFunctions"
    actions   = ["lambda:*"]
    resources = ["arn:${local.partition}:lambda:${var.aws_region}:${local.account_id}:function:${local.prefix}-*"]
  }

  # --- IAM: roles de las Lambdas y de Rekognition ---------------------------------
  statement {
    sid = "ProjectRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.prefix}-*"]
  }

  statement {
    sid       = "PassRolesToLambda"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # El rol de despliegue comparte prefijo: se impide que se modifique a sí mismo.
  statement {
    sid    = "DenySelfModification"
    effect = "Deny"
    actions = [
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [local.deploy_role_arn]
  }

  # --- SNS -----------------------------------------------------------------------
  statement {
    sid       = "ProjectTopics"
    actions   = ["sns:*"]
    resources = ["arn:${local.partition}:sns:${var.aws_region}:${local.account_id}:${local.prefix}-*"]
  }

  # --- CloudWatch Logs -----------------------------------------------------------
  statement {
    sid     = "ProjectLogGroups"
    actions = ["logs:*"]
    resources = [
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.prefix}-*",
      "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/apigateway/${local.prefix}-*",
    ]
  }

  # Lectura de log groups y entrega de access logs de HTTP API: estas acciones
  # no admiten recurso específico.
  statement {
    sid = "LogsAccountLevel"
    actions = [
      "logs:DescribeLogGroups",
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
    ]
    resources = ["*"]
  }

  # --- API Gateway (HTTP API) ------------------------------------------------------
  # Los ARN de API Gateway no incluyen el nombre, así que no se puede acotar por prefijo.
  statement {
    sid = "ApiGateway"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:TagResource",
      "apigateway:UntagResource",
    ]
    resources = ["arn:${local.partition}:apigateway:${var.aws_region}::/*"]
  }

  # --- CloudFront ------------------------------------------------------------------
  # Distribuciones, OAC y políticas tienen IDs aleatorios: no se pueden acotar por nombre.
  statement {
    sid       = "CloudFront"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
