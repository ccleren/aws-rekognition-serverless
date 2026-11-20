"""Lambda Video Result: recoge el resultado de un análisis de vídeo terminado.

Rekognition publica en SNS al acabar StartLabelDetection. Esta función pagina
GetLabelDetection completo, agrega las detecciones por etiqueta y escribe
output-video/<id>.json. Es idempotente: reprocesar el mismo mensaje sobrescribe
el mismo resultado.
"""

import json
import logging
import os
import re
from typing import NamedTuple

import boto3
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

OUTPUT_PREFIX = "output-video/"
MAX_RESULTS_PER_PAGE = 1000

UUID_PATTERN = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
VIDEO_KEY_RE = re.compile(rf"^input/upload-(?P<id>{UUID_PATTERN})\.mp4$")
UUID_RE = re.compile(rf"^{UUID_PATTERN}$")

# Palabras con las que Rekognition describe un vídeo que no puede decodificar
# (solo admite H.264 en MP4/MOV).
CODEC_HINTS = ("codec", "format")

TRANSIENT_ERROR_CODES = frozenset(
    {
        "ThrottlingException",
        "ProvisionedThroughputExceededException",
        "InternalServerError",
        "ServiceUnavailableException",
        "InternalError",
        "ServiceUnavailable",
        "SlowDown",
        "RequestTimeout",
    }
)


class Notification(NamedTuple):
    job_id: str
    status: str
    upload_id: str


class TransientError(Exception):
    """Estado inesperado que puede resolverse reintentando."""


# --- Lógica pura ---------------------------------------------------------------


def parse_notification(message: str) -> Notification | None:
    """Lee el mensaje SNS de Rekognition. None si no permite identificar la subida."""
    try:
        data = json.loads(message)
    except (TypeError, ValueError):
        return None
    if not isinstance(data, dict) or not data.get("JobId"):
        return None

    upload_id = None
    match = VIDEO_KEY_RE.match(data.get("Video", {}).get("S3ObjectName", ""))
    if match:
        upload_id = match["id"]
    elif UUID_RE.match(data.get("JobTag", "")):
        upload_id = data["JobTag"]
    if upload_id is None:
        return None

    return Notification(data["JobId"], data.get("Status", ""), upload_id)


def aggregate_labels(detections: list[dict]) -> list[dict]:
    """Agrupa las detecciones por nombre: confianza máxima, primera y última
    aparición y número de detecciones. Ordenado por primera aparición."""
    by_name: dict[str, dict] = {}
    for detection in detections:
        label = detection.get("Label") or {}
        name = label.get("Name")
        if not name:
            continue
        timestamp = int(detection.get("Timestamp", 0))
        confidence = float(label.get("Confidence", 0.0))

        entry = by_name.get(name)
        if entry is None:
            by_name[name] = {
                "name": name,
                "confidence": confidence,
                "firstSeenMs": timestamp,
                "lastSeenMs": timestamp,
                "occurrences": 1,
            }
            continue
        entry["confidence"] = max(entry["confidence"], confidence)
        entry["firstSeenMs"] = min(entry["firstSeenMs"], timestamp)
        entry["lastSeenMs"] = max(entry["lastSeenMs"], timestamp)
        entry["occurrences"] += 1

    labels = list(by_name.values())
    for entry in labels:
        entry["confidence"] = round(entry["confidence"], 1)
    labels.sort(key=lambda item: (item["firstSeenMs"], -item["confidence"], item["name"]))
    return labels


def build_video_result(duration_ms: int | None, detections: list[dict]) -> dict:
    return {
        "status": "SUCCEEDED",
        "kind": "video",
        "durationMs": int(duration_ms or 0),
        "labels": aggregate_labels(detections),
    }


def classify_failure(status_message: str | None) -> str:
    message = (status_message or "").lower()
    if any(hint in message for hint in CODEC_HINTS):
        return "unsupported_video_codec"
    return "analysis_failed"


def failed_result(error: str) -> dict:
    return {"status": "FAILED", "kind": "video", "error": error}


def result_key(upload_id: str) -> str:
    return f"{OUTPUT_PREFIX}{upload_id}.json"


def is_transient(exc: Exception) -> bool:
    if isinstance(exc, TransientError):
        return True
    if isinstance(exc, ClientError):
        return exc.response.get("Error", {}).get("Code") in TRANSIENT_ERROR_CODES
    return isinstance(exc, BotoCoreError)


# --- AWS -------------------------------------------------------------------------

_clients = {}


def aws_client(name: str):
    if name not in _clients:
        _clients[name] = boto3.client(name)
    return _clients[name]


def write_result(bucket: str, key: str, result: dict) -> None:
    aws_client("s3").put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(result, separators=(",", ":")).encode("utf-8"),
        ContentType="application/json",
        CacheControl="no-store",
    )


def fetch_all_detections(job_id: str) -> tuple[str, str | None, int | None, list[dict]]:
    """Pagina GetLabelDetection hasta agotar NextToken.

    Devuelve (estado del trabajo, mensaje de estado, duración en ms, detecciones).
    """
    rekognition = aws_client("rekognition")
    detections: list[dict] = []
    params = {"JobId": job_id, "MaxResults": MAX_RESULTS_PER_PAGE, "SortBy": "TIMESTAMP"}
    job_status, status_message, duration_ms = "", None, None

    while True:
        page = rekognition.get_label_detection(**params)
        job_status = page.get("JobStatus", "")
        status_message = page.get("StatusMessage")
        if duration_ms is None:
            duration_ms = page.get("VideoMetadata", {}).get("DurationMillis")
        if job_status != "SUCCEEDED":
            break
        detections.extend(page.get("Labels", []))
        token = page.get("NextToken")
        if not token:
            break
        params["NextToken"] = token

    return job_status, status_message, duration_ms, detections


def process_notification(notification: Notification, bucket: str) -> None:
    key = result_key(notification.upload_id)

    if notification.status != "SUCCEEDED":
        # El mensaje SNS no trae el motivo: se consulta para distinguir el códec.
        _, status_message, _, _ = fetch_all_detections(notification.job_id)
        error = classify_failure(status_message)
        write_result(bucket, key, failed_result(error))
        logger.warning("video analysis failed", extra={"id": notification.upload_id, "error": error})
        return

    job_status, _, duration_ms, detections = fetch_all_detections(notification.job_id)
    if job_status == "IN_PROGRESS":
        raise TransientError("job reported as finished but still in progress")
    if job_status != "SUCCEEDED":
        write_result(bucket, key, failed_result("analysis_failed"))
        return

    result = build_video_result(duration_ms, detections)
    write_result(bucket, key, result)
    logger.info(
        "video analyzed",
        extra={"id": notification.upload_id, "detections": len(detections), "labels": len(result["labels"])},
    )


def handler(event, context):
    bucket = os.environ["BUCKET_NAME"]

    for record in event.get("Records", []):
        notification = parse_notification(record.get("Sns", {}).get("Message", ""))
        if notification is None:
            logger.warning("ignored SNS message without a known upload id")
            continue

        try:
            process_notification(notification, bucket)
        except Exception as exc:
            if is_transient(exc):
                logger.warning(
                    "transient error, will retry",
                    extra={"id": notification.upload_id, "error": type(exc).__name__},
                )
                raise
            logger.exception("video result failed", extra={"id": notification.upload_id})
            write_result(bucket, result_key(notification.upload_id), failed_result("processing_failed"))
