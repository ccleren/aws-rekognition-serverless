import base64
import json

import pytest

from conftest import BUCKET, FakeS3, install_clients

JPEG_BYTES = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"\x00" * 32
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
MP4_BYTES = b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 32
HEIC_BYTES = b"\x00\x00\x00\x18ftypheic" + b"\x00" * 32


def api_event(data: bytes, content_type: str = "application/octet-stream", base64_encoded: bool = True) -> dict:
    return {
        "version": "2.0",
        "routeKey": "POST /upload",
        "headers": {"content-type": content_type},
        "isBase64Encoded": base64_encoded,
        "body": base64.b64encode(data).decode() if base64_encoded else data.decode(),
    }


# --- Detección por firma ------------------------------------------------------


@pytest.mark.parametrize(
    ("data", "expected"),
    [
        (JPEG_BYTES, ("image", "jpg", "image/jpeg")),
        (PNG_BYTES, ("image", "png", "image/png")),
        (MP4_BYTES, ("video", "mp4", "video/mp4")),
        (b"\x00\x00\x00\x20ftypisom" + b"\x00" * 8, ("video", "mp4", "video/mp4")),
    ],
)
def test_detect_file_type_known_signatures(upload, data, expected):
    assert tuple(upload.detect_file_type(data)) == expected


@pytest.mark.parametrize(
    "data",
    [
        b"",
        b"hello world, this is plain text",
        b"GIF89a" + b"\x00" * 16,
        b"%PDF-1.7" + b"\x00" * 16,
        HEIC_BYTES,
        b"\x00\x00\x00\x18ftypavif" + b"\x00" * 16,
        b"\xff\xd8",  # JPEG truncado
        b"\x00\x00\x00\x18ftyp",  # ftyp sin marca
    ],
)
def test_detect_file_type_rejects_others(upload, data):
    assert upload.detect_file_type(data) is None


def test_validate_upload_errors(upload):
    with pytest.raises(upload.UploadError) as empty:
        upload.validate_upload(b"", 100)
    assert empty.value.code == "empty_body"

    with pytest.raises(upload.UploadError) as large:
        upload.validate_upload(JPEG_BYTES, len(JPEG_BYTES) - 1)
    assert large.value.code == "file_too_large"

    with pytest.raises(upload.UploadError) as unsupported:
        upload.validate_upload(b"plain text", 100)
    assert unsupported.value.code == "unsupported_type"


def test_validate_upload_accepts_exact_limit(upload):
    assert upload.validate_upload(JPEG_BYTES, len(JPEG_BYTES)).kind == "image"


def test_decode_body_variants(upload):
    assert upload.decode_body({"body": None}) == b""
    assert upload.decode_body({"body": "abc", "isBase64Encoded": False}) == b"abc"
    assert upload.decode_body({"body": base64.b64encode(PNG_BYTES).decode(), "isBase64Encoded": True}) == PNG_BYTES
    with pytest.raises(upload.UploadError):
        upload.decode_body({"body": "not base64!!", "isBase64Encoded": True})


def test_build_input_key(upload):
    assert upload.build_input_key("abc", "jpg") == "input/upload-abc.jpg"


# --- Handler -------------------------------------------------------------------


def test_handler_stores_jpeg_ignoring_declared_content_type(upload):
    """Un JPEG enviado como image/png (caso real de los ejemplos) se guarda como JPEG."""
    s3 = FakeS3()
    install_clients(upload, s3=s3)

    response = upload.handler(api_event(JPEG_BYTES, content_type="image/png"), None)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["kind"] == "image"
    key = f"input/upload-{body['id']}.jpg"
    assert s3.objects[key]["Bucket"] == BUCKET
    assert s3.objects[key]["ContentType"] == "image/jpeg"
    assert s3.objects[key]["Body"] == JPEG_BYTES


def test_handler_stores_video(upload):
    s3 = FakeS3()
    install_clients(upload, s3=s3)

    body = json.loads(upload.handler(api_event(MP4_BYTES), None)["body"])

    assert body["kind"] == "video"
    assert s3.objects[f"input/upload-{body['id']}.mp4"]["ContentType"] == "video/mp4"


@pytest.mark.parametrize(
    ("event", "error"),
    [
        ({"body": None, "isBase64Encoded": False}, "empty_body"),
        (api_event(b"\xff\xd8\xff" + b"\x00" * 2000), "file_too_large"),
        (api_event(b"just some text", content_type="image/jpeg"), "unsupported_type"),
        (api_event(HEIC_BYTES, content_type="video/mp4"), "unsupported_type"),
    ],
)
def test_handler_rejects_invalid_uploads_without_storing(upload, event, error):
    s3 = FakeS3()
    install_clients(upload, s3=s3)

    response = upload.handler(event, None)

    assert response["statusCode"] == 400
    assert json.loads(response["body"]) == {"error": error}
    assert s3.objects == {}


def test_handler_hides_internal_errors(upload):
    install_clients(upload, s3=FakeS3(error=RuntimeError("secret detail")))

    response = upload.handler(api_event(PNG_BYTES), None)

    assert response["statusCode"] == 500
    assert json.loads(response["body"]) == {"error": "internal_error"}
    assert "secret" not in response["body"]
