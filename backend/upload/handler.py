"""Lambda Upload: recibe un archivo por POST /upload y lo guarda en input/.

El tipo se decide por la firma del archivo (magic bytes), nunca por el
Content-Type que declara el cliente. Lo que no sea JPEG, PNG o MP4 se rechaza
con 400 y no llega a guardarse.
"""

import base64
import binascii
import json
import logging
import os
import uuid
from typing import NamedTuple

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

DEFAULT_MAX_UPLOAD_BYTES = 4 * 1024 * 1024
INPUT_PREFIX = "input/"

JPEG_SIGNATURE = b"\xff\xd8\xff"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# Las imágenes HEIF/AVIF también usan la caja "ftyp" de ISO BMFF. Se descartan
# por su marca para no tratarlas como vídeo (Rekognition no las admite).
NON_VIDEO_FTYP_BRANDS = frozenset(
    {b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx", b"hevm", b"hevs",
     b"mif1", b"msf1", b"avif", b"avis", b"crx "}
)


class FileType(NamedTuple):
    kind: str  # "image" | "video"
    extension: str
    content_type: str


JPEG = FileType("image", "jpg", "image/jpeg")
PNG = FileType("image", "png", "image/png")
MP4 = FileType("video", "mp4", "video/mp4")


class UploadError(Exception):
    """Error de validación que se devuelve al cliente como 400."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


# --- Lógica pura ---------------------------------------------------------------


def detect_file_type(data: bytes) -> FileType | None:
    """Identifica JPEG, PNG o MP4 por su firma. Devuelve None si no es ninguno."""
    if data.startswith(JPEG_SIGNATURE):
        return JPEG
    if data.startswith(PNG_SIGNATURE):
        return PNG
    if len(data) >= 12 and data[4:8] == b"ftyp" and data[8:12] not in NON_VIDEO_FTYP_BRANDS:
        return MP4
    return None


def decode_body(event: dict) -> bytes:
    """Devuelve el cuerpo de la petición (payload 2.0 de HTTP API) en bytes."""
    body = event.get("body")
    if not body:
        return b""
    if event.get("isBase64Encoded"):
        try:
            return base64.b64decode(body, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise UploadError("unsupported_type") from exc
    return body.encode("utf-8")


def validate_upload(data: bytes, max_bytes: int) -> FileType:
    """Comprueba tamaño y tipo. Lanza UploadError con el código para el cliente."""
    if not data:
        raise UploadError("empty_body")
    if len(data) > max_bytes:
        raise UploadError("file_too_large")
    file_type = detect_file_type(data)
    if file_type is None:
        raise UploadError("unsupported_type")
    return file_type


def build_input_key(upload_id: str, extension: str) -> str:
    return f"{INPUT_PREFIX}upload-{upload_id}.{extension}"


def json_response(status_code: int, body: dict) -> dict:
    # Las cabeceras CORS las añade API Gateway según su configuración.
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


# --- AWS -------------------------------------------------------------------------

_s3 = None


def s3_client():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    return _s3


def handler(event, context):
    bucket = os.environ["BUCKET_NAME"]
    max_bytes = int(os.environ.get("MAX_UPLOAD_BYTES", DEFAULT_MAX_UPLOAD_BYTES))

    try:
        data = decode_body(event)
        file_type = validate_upload(data, max_bytes)
    except UploadError as exc:
        logger.info("upload rejected", extra={"reason": exc.code})
        return json_response(400, {"error": exc.code})

    upload_id = str(uuid.uuid4())
    key = build_input_key(upload_id, file_type.extension)

    try:
        s3_client().put_object(
            Bucket=bucket,
            Key=key,
            Body=data,
            ContentType=file_type.content_type,
        )
    except Exception:
        logger.exception("upload failed", extra={"id": upload_id})
        return json_response(500, {"error": "internal_error"})

    logger.info("upload stored", extra={"id": upload_id, "kind": file_type.kind, "bytes": len(data)})
    return json_response(200, {"id": upload_id, "kind": file_type.kind})
