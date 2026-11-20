"""Lambda Process: analiza lo que llega a input/ (evento ObjectCreated de S3).

- Imagen: DetectLabels (síncrono) y resultado en output/<id>.json.
- Vídeo: StartLabelDetection (asíncrono). Rekognition avisa por SNS al terminar
  y Video Result escribe el resultado. Aquí no se espera ni se escribe nada.

Errores transitorios (throttling, red) se relanzan para que Lambda reintente la
invocación asíncrona. El resto se escribe como resultado FAILED para que el
frontend deje de esperar.
"""

import json
import logging
import os
import re
from typing import NamedTuple
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

INPUT_PREFIX = "input/"
OUTPUT_PREFIX = {"image": "output/", "video": "output-video/"}
KIND_BY_EXTENSION = {"jpg": "image", "png": "image", "mp4": "video"}

INPUT_KEY_RE = re.compile(
    r"^input/upload-(?P<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
    r"\.(?P<ext>jpg|png|mp4)$"
)

TRANSIENT_ERROR_CODES = frozenset(
    {
        "ThrottlingException",
        "ProvisionedThroughputExceededException",
        "LimitExceededException",  # demasiados trabajos de vídeo simultáneos
        "InternalServerError",
        "ServiceUnavailableException",
        "InternalError",
        "ServiceUnavailable",
        "SlowDown",
        "RequestTimeout",
    }
)


class InputObject(NamedTuple):
    upload_id: str
    kind: str


# --- Lógica pura ---------------------------------------------------------------


def parse_input_key(key: str) -> InputObject | None:
    """Extrae id y tipo de input/upload-<uuid>.<ext>. None si la clave no es nuestra."""
    match = INPUT_KEY_RE.match(key)
    if not match:
        return None
    return InputObject(match["id"], KIND_BY_EXTENSION[match["ext"]])


def result_key(kind: str, upload_id: str) -> str:
    return f"{OUTPUT_PREFIX[kind]}{upload_id}.json"


def normalize_bounding_box(box: dict) -> dict:
    return {
        "left": round(box.get("Left", 0.0), 4),
        "top": round(box.get("Top", 0.0), 4),
        "width": round(box.get("Width", 0.0), 4),
        "height": round(box.get("Height", 0.0), 4),
    }


def normalize_image_labels(response: dict) -> dict:
    """Convierte la respuesta de DetectLabels al esquema de resultado de imagen."""
    labels = [
        {
            "name": label["Name"],
            "confidence": round(label["Confidence"], 1),
            "instances": [
                {"boundingBox": normalize_bounding_box(instance["BoundingBox"])}
                for instance in label.get("Instances", [])
                if "BoundingBox" in instance
            ],
        }
        for label in response.get("Labels", [])
    ]
    labels.sort(key=lambda item: (-item["confidence"], item["name"]))
    return {"status": "SUCCEEDED", "kind": "image", "labels": labels}


def failed_result(kind: str, error: str) -> dict:
    return {"status": "FAILED", "kind": kind, "error": error}


def is_transient(exc: Exception) -> bool:
    """True si merece la pena reintentar (throttling, errores 5xx, fallos de red)."""
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


def analyze_image(bucket: str, key: str, item: InputObject) -> None:
    response = aws_client("rekognition").detect_labels(
        Image={"S3Object": {"Bucket": bucket, "Name": key}},
        MaxLabels=int(os.environ.get("MAX_LABELS", "10")),
        MinConfidence=float(os.environ.get("MIN_CONFIDENCE", "75")),
    )
    write_result(bucket, result_key("image", item.upload_id), normalize_image_labels(response))
    logger.info("image analyzed", extra={"id": item.upload_id, "labels": len(response.get("Labels", []))})


def start_video_analysis(bucket: str, key: str, item: InputObject) -> None:
    # ClientRequestToken = id: si Lambda reintenta, Rekognition devuelve el mismo
    # JobId en lugar de lanzar (y cobrar) un segundo análisis.
    response = aws_client("rekognition").start_label_detection(
        Video={"S3Object": {"Bucket": bucket, "Name": key}},
        ClientRequestToken=item.upload_id,
        JobTag=item.upload_id,
        MinConfidence=float(os.environ.get("MIN_CONFIDENCE", "75")),
        NotificationChannel={
            "SNSTopicArn": os.environ["SNS_TOPIC_ARN"],
            "RoleArn": os.environ["REKOGNITION_ROLE_ARN"],
        },
    )
    logger.info("video analysis started", extra={"id": item.upload_id, "job_id": response["JobId"]})


def process_record(record: dict, bucket: str) -> None:
    record_bucket = record["s3"]["bucket"]["name"]
    key = unquote_plus(record["s3"]["object"]["key"])

    # Defensa en profundidad: la notificación ya filtra por input/, pero nunca
    # se procesa nada fuera de ese prefijo ni de otro bucket (evita bucles).
    if record_bucket != bucket or not key.startswith(INPUT_PREFIX):
        logger.warning("ignored object outside input/", extra={"bucket": record_bucket})
        return

    item = parse_input_key(key)
    if item is None:
        logger.warning("ignored unexpected input key")
        return

    try:
        if item.kind == "image":
            analyze_image(bucket, key, item)
        else:
            start_video_analysis(bucket, key, item)
    except Exception as exc:
        if is_transient(exc):
            logger.warning("transient error, will retry", extra={"id": item.upload_id, "error": type(exc).__name__})
            raise
        logger.exception("analysis failed", extra={"id": item.upload_id})
        write_result(bucket, result_key(item.kind, item.upload_id), failed_result(item.kind, "processing_failed"))


def handler(event, context):
    bucket = os.environ["BUCKET_NAME"]
    for record in event.get("Records", []):
        process_record(record, bucket)
