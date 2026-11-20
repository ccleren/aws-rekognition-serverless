import pytest

from conftest import BUCKET, UPLOAD_ID, FakeRekognition, FakeS3, client_error, install_clients

DETECT_LABELS_RESPONSE = {
    "Labels": [
        {"Name": "Outdoors", "Confidence": 91.23456, "Instances": []},
        {
            "Name": "Dog",
            "Confidence": 99.34567,
            "Instances": [
                {"BoundingBox": {"Left": 0.123456, "Top": 0.2, "Width": 0.5, "Height": 0.654321}, "Confidence": 99.0},
                {"Confidence": 80.0},  # instancia sin caja: se descarta
            ],
        },
    ]
}


def s3_event(key: str, bucket: str = BUCKET) -> dict:
    return {"Records": [{"s3": {"bucket": {"name": bucket}, "object": {"key": key}}}]}


# --- Lógica pura -----------------------------------------------------------------


def test_parse_input_key(process):
    assert process.parse_input_key(f"input/upload-{UPLOAD_ID}.jpg") == (UPLOAD_ID, "image")
    assert process.parse_input_key(f"input/upload-{UPLOAD_ID}.png") == (UPLOAD_ID, "image")
    assert process.parse_input_key(f"input/upload-{UPLOAD_ID}.mp4") == (UPLOAD_ID, "video")


@pytest.mark.parametrize(
    "key",
    [
        f"output/{UPLOAD_ID}.json",
        f"input/upload-{UPLOAD_ID}.bin",
        f"input/upload-{UPLOAD_ID}.jpg.exe",
        "input/upload-not-a-uuid.jpg",
        f"input/other-{UPLOAD_ID}.jpg",
    ],
)
def test_parse_input_key_rejects_foreign_keys(process, key):
    assert process.parse_input_key(key) is None


def test_result_key(process):
    assert process.result_key("image", "abc") == "output/abc.json"
    assert process.result_key("video", "abc") == "output-video/abc.json"


def test_normalize_image_labels(process):
    result = process.normalize_image_labels(DETECT_LABELS_RESPONSE)

    assert result == {
        "status": "SUCCEEDED",
        "kind": "image",
        "labels": [
            {
                "name": "Dog",
                "confidence": 99.3,
                "instances": [{"boundingBox": {"left": 0.1235, "top": 0.2, "width": 0.5, "height": 0.6543}}],
            },
            {"name": "Outdoors", "confidence": 91.2, "instances": []},
        ],
    }


def test_normalize_image_labels_empty(process):
    assert process.normalize_image_labels({})["labels"] == []


def test_is_transient(process):
    assert process.is_transient(client_error("ThrottlingException"))
    assert process.is_transient(client_error("LimitExceededException"))
    assert not process.is_transient(client_error("InvalidImageFormatException"))
    assert not process.is_transient(client_error("AccessDeniedException"))
    assert not process.is_transient(ValueError("bug"))


# --- Handler -------------------------------------------------------------------------


def test_image_is_analyzed_and_written(process):
    s3, rekognition = FakeS3(), FakeRekognition(detect_labels=DETECT_LABELS_RESPONSE)
    install_clients(process, s3=s3, rekognition=rekognition)

    process.handler(s3_event(f"input/upload-{UPLOAD_ID}.jpg"), None)

    name, params = rekognition.calls[0]
    assert name == "detect_labels"
    assert params["Image"] == {"S3Object": {"Bucket": BUCKET, "Name": f"input/upload-{UPLOAD_ID}.jpg"}}
    assert params["MaxLabels"] == 10
    assert params["MinConfidence"] == 75.0

    stored = s3.objects[f"output/{UPLOAD_ID}.json"]
    assert stored["ContentType"] == "application/json"
    assert stored["CacheControl"] == "no-store"
    assert s3.json_body(f"output/{UPLOAD_ID}.json")["labels"][0]["name"] == "Dog"


def test_url_encoded_key_is_decoded(process):
    s3, rekognition = FakeS3(), FakeRekognition()
    install_clients(process, s3=s3, rekognition=rekognition)

    process.handler(s3_event(f"input%2Fupload-{UPLOAD_ID}.png"), None)

    assert rekognition.calls[0][1]["Image"]["S3Object"]["Name"] == f"input/upload-{UPLOAD_ID}.png"


def test_video_starts_idempotent_job_without_writing(process):
    s3, rekognition = FakeS3(), FakeRekognition()
    install_clients(process, s3=s3, rekognition=rekognition)

    process.handler(s3_event(f"input/upload-{UPLOAD_ID}.mp4"), None)

    name, params = rekognition.calls[0]
    assert name == "start_label_detection"
    assert params["ClientRequestToken"] == UPLOAD_ID
    assert params["JobTag"] == UPLOAD_ID
    assert params["MinConfidence"] == 75.0
    assert params["NotificationChannel"] == {
        "SNSTopicArn": "arn:aws:sns:us-east-1:000000000000:test-topic",
        "RoleArn": "arn:aws:iam::000000000000:role/test-role",
    }
    assert s3.objects == {}


@pytest.mark.parametrize(
    "key",
    [f"output/{UPLOAD_ID}.json", f"output-video/{UPLOAD_ID}.json", "input/whatever.txt"],
)
def test_objects_outside_contract_are_ignored(process, key):
    s3, rekognition = FakeS3(), FakeRekognition()
    install_clients(process, s3=s3, rekognition=rekognition)

    process.handler(s3_event(key), None)

    assert rekognition.calls == []
    assert s3.objects == {}


def test_other_bucket_is_ignored(process):
    s3, rekognition = FakeS3(), FakeRekognition()
    install_clients(process, s3=s3, rekognition=rekognition)

    process.handler(s3_event(f"input/upload-{UPLOAD_ID}.jpg", bucket="someone-else"), None)

    assert rekognition.calls == []


@pytest.mark.parametrize(
    ("extension", "kind", "result_key"),
    [("jpg", "image", f"output/{UPLOAD_ID}.json"), ("mp4", "video", f"output-video/{UPLOAD_ID}.json")],
)
def test_non_recoverable_error_writes_failed(process, extension, kind, result_key):
    error = client_error("InvalidS3ObjectException")
    s3 = FakeS3()
    install_clients(process, s3=s3, rekognition=FakeRekognition(detect_error=error, start_error=error))

    process.handler(s3_event(f"input/upload-{UPLOAD_ID}.{extension}"), None)

    assert s3.json_body(result_key) == {"status": "FAILED", "kind": kind, "error": "processing_failed"}


def test_transient_error_is_raised_for_retry(process):
    s3 = FakeS3()
    install_clients(process, s3=s3, rekognition=FakeRekognition(detect_error=client_error("ThrottlingException")))

    with pytest.raises(Exception):
        process.handler(s3_event(f"input/upload-{UPLOAD_ID}.jpg"), None)

    assert s3.objects == {}
