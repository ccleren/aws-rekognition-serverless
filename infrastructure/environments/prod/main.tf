data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Los nombres de bucket se calculan aquí (y no en el módulo storage) para poder
# usarlos en las políticas de las Lambdas y en la notificación de S3 sin crear
# un ciclo bucket → Lambda → notificación.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  prefix     = var.project_name
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  frontend_bucket_name = "${local.prefix}-frontend-${random_id.suffix.hex}"
  data_bucket_name     = "${local.prefix}-data-${random_id.suffix.hex}"
  data_bucket_arn      = "arn:${local.partition}:s3:::${local.data_bucket_name}"

  backend_dir = "${path.module}/../../../backend"
  build_dir   = "${path.module}/build"

  site_origin = "https://${module.cloudfront.domain_name}"
}

# --- Almacenamiento ---------------------------------------------------------------

module "storage" {
  source = "../../modules/storage"

  frontend_bucket_name        = local.frontend_bucket_name
  data_bucket_name            = local.data_bucket_name
  cloudfront_distribution_arn = module.cloudfront.distribution_arn
  data_retention_days         = var.data_retention_days
  force_destroy               = var.force_destroy
}

# --- Lambda Upload -------------------------------------------------------------------

data "aws_iam_policy_document" "upload" {
  statement {
    sid       = "PutInput"
    actions   = ["s3:PutObject"]
    resources = ["${local.data_bucket_arn}/input/*"]
  }
}

module "upload" {
  source = "../../modules/lambda-function"

  function_name      = "${local.prefix}-upload"
  description        = "Valida el archivo por su firma y lo guarda en input/."
  source_file        = "${local.backend_dir}/upload/handler.py"
  build_dir          = local.build_dir
  timeout            = 15
  policy_json        = data.aws_iam_policy_document.upload.json
  log_retention_days = var.log_retention_days

  environment = {
    BUCKET_NAME      = local.data_bucket_name
    MAX_UPLOAD_BYTES = tostring(var.max_upload_bytes)
  }
}

# --- Lambda Process -------------------------------------------------------------------

data "aws_iam_policy_document" "process" {
  # Rekognition lee la imagen/vídeo de S3 con los permisos de quien llama.
  statement {
    sid       = "ReadInput"
    actions   = ["s3:GetObject"]
    resources = ["${local.data_bucket_arn}/input/*"]
  }

  statement {
    sid     = "WriteResults"
    actions = ["s3:PutObject"]
    resources = [
      "${local.data_bucket_arn}/output/*",
      "${local.data_bucket_arn}/output-video/*",
    ]
  }

  # Estas acciones de Rekognition no admiten permisos a nivel de recurso.
  statement {
    sid       = "Rekognition"
    actions   = ["rekognition:DetectLabels", "rekognition:StartLabelDetection"]
    resources = ["*"]
  }

  statement {
    sid       = "PassRekognitionRole"
    actions   = ["iam:PassRole"]
    resources = [module.rekognition_sns.rekognition_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["rekognition.amazonaws.com"]
    }
  }
}

module "process" {
  source = "../../modules/lambda-function"

  function_name        = "${local.prefix}-process"
  description          = "Analiza input/: DetectLabels (imagen) o StartLabelDetection (vídeo)."
  source_file          = "${local.backend_dir}/process/handler.py"
  build_dir            = local.build_dir
  timeout              = 30
  policy_json          = data.aws_iam_policy_document.process.json
  log_retention_days   = var.log_retention_days
  reserved_concurrency = var.process_reserved_concurrency

  environment = {
    BUCKET_NAME          = local.data_bucket_name
    SNS_TOPIC_ARN        = module.rekognition_sns.topic_arn
    REKOGNITION_ROLE_ARN = module.rekognition_sns.rekognition_role_arn
    MIN_CONFIDENCE       = tostring(var.min_confidence)
    MAX_LABELS           = tostring(var.max_labels)
  }
}

# S3 → Process. source_account evita que otra cuenta con un bucket del mismo
# nombre (tras borrarse este) pueda invocar la función.
resource "aws_lambda_permission" "s3_invoke_process" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = module.process.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = local.data_bucket_arn
  source_account = local.account_id
}

# Solo input/: las Lambdas escriben en output/ y output-video/, así que no hay bucle.
resource "aws_s3_bucket_notification" "data" {
  bucket = module.storage.data_bucket_id

  lambda_function {
    lambda_function_arn = module.process.function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "input/"
  }

  depends_on = [aws_lambda_permission.s3_invoke_process]
}

# --- Lambda Video Result + SNS ------------------------------------------------------------

data "aws_iam_policy_document" "video_result" {
  statement {
    sid       = "Rekognition"
    actions   = ["rekognition:GetLabelDetection"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteVideoResults"
    actions   = ["s3:PutObject"]
    resources = ["${local.data_bucket_arn}/output-video/*"]
  }
}

module "video_result" {
  source = "../../modules/lambda-function"

  function_name      = "${local.prefix}-video-result"
  description        = "Pagina GetLabelDetection, agrega por etiqueta y escribe output-video/."
  source_file        = "${local.backend_dir}/video_result/handler.py"
  build_dir          = local.build_dir
  timeout            = 60
  policy_json        = data.aws_iam_policy_document.video_result.json
  log_retention_days = var.log_retention_days

  environment = {
    BUCKET_NAME = local.data_bucket_name
  }
}

module "rekognition_sns" {
  source = "../../modules/rekognition-sns"

  name_prefix              = local.prefix
  subscriber_function_name = module.video_result.function_name
  subscriber_function_arn  = module.video_result.function_arn
}

# --- API Gateway -----------------------------------------------------------------------------

module "api" {
  source = "../../modules/api-gateway"

  name                 = "${local.prefix}-api"
  lambda_function_name = module.upload.function_name
  lambda_invoke_arn    = module.upload.invoke_arn
  allowed_origins      = concat([local.site_origin], var.extra_allowed_origins)
  throttle_rate        = var.api_throttle_rate
  throttle_burst       = var.api_throttle_burst
  log_retention_days   = var.log_retention_days
}

# --- CloudFront -------------------------------------------------------------------------------

module "cloudfront" {
  source = "../../modules/cloudfront"

  name_prefix                          = local.prefix
  frontend_bucket_id                   = module.storage.frontend_bucket_id
  frontend_bucket_regional_domain_name = module.storage.frontend_bucket_regional_domain_name
  data_bucket_id                       = module.storage.data_bucket_id
  data_bucket_regional_domain_name     = module.storage.data_bucket_regional_domain_name
  extra_allowed_origins                = var.extra_allowed_origins
  price_class                          = var.price_class

  # Comodín de API Gateway en la región: el endpoint exacto crearía un ciclo
  # (el CORS del API depende del dominio de CloudFront).
  csp_connect_src = ["https://*.execute-api.${var.aws_region}.amazonaws.com"]
}

# --- config.js del frontend -------------------------------------------------------------------
# Generado aquí con los endpoints reales; no se versiona. El pipeline sincroniza
# frontend/ con --exclude config.js para no borrarlo.

resource "aws_s3_object" "config_js" {
  bucket        = module.storage.frontend_bucket_id
  key           = "config.js"
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache"

  content = templatefile("${path.module}/config.js.tftpl", {
    config = {
      APP_NAME              = var.app_name
      API_URL               = module.api.api_endpoint
      RESULTS_BASE_URL      = local.site_origin
      MAX_UPLOAD_BYTES      = var.max_upload_bytes
      MIN_CONFIDENCE        = var.min_confidence
      POLL_INITIAL_DELAY_MS = 1000
      POLL_MAX_DELAY_MS     = 4000
      POLL_IMAGE_TIMEOUT_MS = var.poll_image_timeout_seconds * 1000
      POLL_VIDEO_TIMEOUT_MS = var.poll_video_timeout_seconds * 1000
      DATA_RETENTION_HOURS  = var.data_retention_days * 24
    }
  })
}
