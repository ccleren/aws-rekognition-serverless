# Dos buckets privados: la web (frontend) y los datos de usuario (data).
# Ninguno es público: CloudFront los lee con Origin Access Control y la política
# de cada bucket solo admite esa distribución. La notificación data → Process se
# define en el entorno (evita el ciclo bucket ↔ Lambda).

locals {
  buckets = {
    frontend = var.frontend_bucket_name
    data     = var.data_bucket_name
  }

  # Prefijos con expiración automática. input/ nunca se expone por CloudFront.
  data_prefixes        = ["input/", "output/", "output-video/"]
  public_read_prefixes = ["output/", "output-video/"]
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.this["data"].id

  dynamic "rule" {
    for_each = local.data_prefixes

    content {
      id     = "expire-${trimsuffix(rule.value, "/")}"
      status = "Enabled"

      filter {
        prefix = rule.value
      }

      expiration {
        days = var.data_retention_days
      }
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- Políticas de bucket -------------------------------------------------------

data "aws_iam_policy_document" "deny_insecure_transport" {
  for_each = aws_s3_bucket.this

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

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

data "aws_iam_policy_document" "frontend" {
  source_policy_documents = [data.aws_iam_policy_document.deny_insecure_transport["frontend"].json]

  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["frontend"].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [var.cloudfront_distribution_arn]
    }
  }
}

# Solo los resultados son legibles por CloudFront. Sin s3:ListBucket, una clave
# que aún no existe devuelve 403 (el frontend lo trata como "todavía no").
data "aws_iam_policy_document" "data" {
  source_policy_documents = [data.aws_iam_policy_document.deny_insecure_transport["data"].json]

  statement {
    sid       = "AllowCloudFrontReadResults"
    actions   = ["s3:GetObject"]
    resources = [for prefix in local.public_read_prefixes : "${aws_s3_bucket.this["data"].arn}/${prefix}*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [var.cloudfront_distribution_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.this["frontend"].id
  policy = data.aws_iam_policy_document.frontend.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.this["data"].id
  policy = data.aws_iam_policy_document.data.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
