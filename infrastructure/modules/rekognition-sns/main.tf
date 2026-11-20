# Canal de finalización de Rekognition Video:
# StartLabelDetection (Process) → Rekognition publica en este topic al terminar
# (asumiendo el rol de servicio) → suscripción → Lambda Video Result.
#
# El rol solo necesita sns:Publish. Rekognition lee el vídeo de S3 con los
# permisos de quien llama a StartLabelDetection (la Lambda Process), no con este
# rol (ver "Configuring Amazon Rekognition Video" en la documentación de AWS).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
}

# Sin cifrado KMS: los mensajes solo contienen JobId, estado y la clave del
# vídeo. Cifrarlo obligaría a dar permisos de KMS al rol de Rekognition.
resource "aws_sns_topic" "video_done" {
  name = "${var.name_prefix}-video-done"
}

# --- Rol de servicio de Rekognition ------------------------------------------------
# Las condiciones aws:SourceAccount y aws:SourceArn evitan el "confused deputy":
# solo Rekognition actuando en nombre de esta cuenta puede asumirlo.

data "aws_iam_policy_document" "rekognition_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["rekognition.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:rekognition:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "rekognition" {
  name               = "${var.name_prefix}-rekognition-sns"
  description        = "Permite a Rekognition Video publicar la finalización de análisis en SNS."
  assume_role_policy = data.aws_iam_policy_document.rekognition_assume.json
}

data "aws_iam_policy_document" "rekognition" {
  statement {
    sid       = "PublishVideoDone"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.video_done.arn]
  }
}

resource "aws_iam_role_policy" "rekognition" {
  name   = "inline"
  role   = aws_iam_role.rekognition.id
  policy = data.aws_iam_policy_document.rekognition.json
}

# --- Suscripción → Video Result --------------------------------------------------------

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSnsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.subscriber_function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.video_done.arn
}

resource "aws_sns_topic_subscription" "video_result" {
  topic_arn = aws_sns_topic.video_done.arn
  protocol  = "lambda"
  endpoint  = var.subscriber_function_arn

  depends_on = [aws_lambda_permission.sns]
}
