# Una distribución con dos orígenes privados (OAC):
#   /               → bucket frontend (caché optimizada)
#   /output/*       → bucket data     (sin caché: el frontend hace polling)
#   /output-video/* → bucket data     (sin caché)
# Las rutas coinciden con las claves de S3, así que no hay reescritura.
# input/ no tiene comportamiento y la política del bucket tampoco lo permite.

locals {
  frontend_origin_id = "frontend"
  data_origin_id     = "data"
  results_paths      = ["output/*", "output-video/*"]

  csp = join("; ", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' blob: data:",
    "media-src 'self' blob:",
    "font-src 'self'",
    "connect-src ${join(" ", concat(["'self'"], var.csp_connect_src))}",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ])

  permissions_policy = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${var.name_prefix}-s3"
  description                       = "Acceso de CloudFront a los buckets privados de ${var.name_prefix}."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- Cabeceras de seguridad -------------------------------------------------------

resource "aws_cloudfront_response_headers_policy" "site" {
  name    = "${var.name_prefix}-site"
  comment = "Cabeceras de seguridad y CSP de la web."

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    content_security_policy {
      content_security_policy = local.csp
      override                = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = local.permissions_policy
      override = true
    }
  }
}

# Los resultados son JSON: mismas cabeceras de seguridad y, si se piden orígenes
# extra (desarrollo local), CORS para que puedan leerlos.
resource "aws_cloudfront_response_headers_policy" "results" {
  name    = "${var.name_prefix}-results"
  comment = "Cabeceras de seguridad de los resultados (y CORS para orígenes de desarrollo)."

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    content_security_policy {
      content_security_policy = "default-src 'none'; frame-ancestors 'none'"
      override                = true
    }
  }

  dynamic "cors_config" {
    for_each = length(var.extra_allowed_origins) > 0 ? [1] : []

    content {
      access_control_allow_credentials = false
      access_control_max_age_sec       = 3600
      origin_override                  = true

      access_control_allow_headers {
        items = ["*"]
      }

      access_control_allow_methods {
        items = ["GET", "HEAD", "OPTIONS"]
      }

      access_control_allow_origins {
        items = var.extra_allowed_origins
      }
    }
  }
}

# --- Distribución -------------------------------------------------------------------

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "${var.name_prefix} — web y resultados"
  default_root_object = "index.html"
  price_class         = var.price_class
  http_version        = "http2and3"
  is_ipv6_enabled     = true

  origin {
    origin_id                = local.frontend_origin_id
    domain_name              = var.frontend_bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    origin_id                = local.data_origin_id
    domain_name              = var.data_bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  default_cache_behavior {
    target_origin_id           = local.frontend_origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.results_paths

    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = local.data_origin_id
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD", "OPTIONS"]
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.results.id
    }
  }

  # Sin esto CloudFront cachea ~10 s el 403/404 de un resultado que aún no
  # existe y el polling parece colgado. No se redirige a ninguna página: no es
  # una SPA y el frontend necesita ver el código de error real.
  dynamic "custom_error_response" {
    for_each = [403, 404]

    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Certificado por defecto de *.cloudfront.net. Con él no se puede fijar TLS 1.2
  # como mínimo; eso requiere dominio propio + ACM (fuera de alcance).
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
