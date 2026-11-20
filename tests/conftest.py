"""Utilidades comunes para los tests.

Las tres Lambdas se llaman handler.py, así que se cargan con nombres de módulo
distintos. Los clientes de AWS se sustituyen por dobles en memoria: ningún test
llama a AWS.
"""

import importlib.util
import json
from pathlib import Path

import pytest
from botocore.exceptions import ClientError

BACKEND_DIR = Path(__file__).resolve().parent.parent / "backend"

BUCKET = "test-data-bucket"
UPLOAD_ID = "0b6f7c1e-2d4a-4c8e-9f10-123456789abc"


def load_handler(function_dir: str):
    path = BACKEND_DIR / function_dir / "handler.py"
    spec = importlib.util.spec_from_file_location(f"{function_dir}_handler", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def client_error(code: str, operation: str = "Operation") -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": code}}, operation)


class FakeS3:
    def __init__(self, error: Exception | None = None):
        self.objects: dict[str, dict] = {}
        self.error = error

    def put_object(self, **kwargs):
        if self.error:
            raise self.error
        self.objects[kwargs["Key"]] = kwargs
        return {}

    def json_body(self, key: str) -> dict:
        return json.loads(self.objects[key]["Body"])


class FakeRekognition:
    def __init__(self, detect_labels=None, start_error=None, pages=None, detect_error=None):
        self.detect_labels_response = detect_labels or {"Labels": []}
        self.detect_error = detect_error
        self.start_error = start_error
        self.pages = pages or []
        self.calls: list[tuple[str, dict]] = []

    def detect_labels(self, **kwargs):
        self.calls.append(("detect_labels", kwargs))
        if self.detect_error:
            raise self.detect_error
        return self.detect_labels_response

    def start_label_detection(self, **kwargs):
        self.calls.append(("start_label_detection", kwargs))
        if self.start_error:
            raise self.start_error
        return {"JobId": "job-123"}

    def get_label_detection(self, **kwargs):
        self.calls.append(("get_label_detection", kwargs))
        index = sum(1 for name, _ in self.calls if name == "get_label_detection") - 1
        return self.pages[index]


@pytest.fixture
def upload(monkeypatch):
    monkeypatch.setenv("BUCKET_NAME", BUCKET)
    monkeypatch.setenv("MAX_UPLOAD_BYTES", "1024")
    return load_handler("upload")


@pytest.fixture
def process(monkeypatch):
    monkeypatch.setenv("BUCKET_NAME", BUCKET)
    monkeypatch.setenv("SNS_TOPIC_ARN", "arn:aws:sns:us-east-1:000000000000:test-topic")
    monkeypatch.setenv("REKOGNITION_ROLE_ARN", "arn:aws:iam::000000000000:role/test-role")
    monkeypatch.setenv("MIN_CONFIDENCE", "75")
    monkeypatch.setenv("MAX_LABELS", "10")
    return load_handler("process")


@pytest.fixture
def video_result(monkeypatch):
    monkeypatch.setenv("BUCKET_NAME", BUCKET)
    return load_handler("video_result")


def install_clients(module, **clients):
    """Sustituye los clientes de boto3 del módulo por los dobles indicados."""
    if hasattr(module, "_clients"):
        module._clients.clear()
        module._clients.update(clients)
    else:
        module._s3 = clients["s3"]
