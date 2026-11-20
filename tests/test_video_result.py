import json

import pytest

from conftest import BUCKET, UPLOAD_ID, FakeRekognition, FakeS3, client_error, install_clients

RESULT_KEY = f"output-video/{UPLOAD_ID}.json"


def rekognition_message(status: str = "SUCCEEDED", **overrides) -> str:
    message = {
        "JobId": "job-123",
        "Status": status,
        "API": "StartLabelDetection",
        "JobTag": UPLOAD_ID,
        "Timestamp": 1700000000000,
        "Video": {"S3ObjectName": f"input/upload-{UPLOAD_ID}.mp4", "S3Bucket": BUCKET},
    }
    message.update(overrides)
    return json.dumps(message)


def sns_event(message: str) -> dict:
    return {"Records": [{"EventSource": "aws:sns", "Sns": {"Message": message}}]}


def detection(timestamp: int, name: str, confidence: float) -> dict:
    return {"Timestamp": timestamp, "Label": {"Name": name, "Confidence": confidence}}


# --- Lógica pura -------------------------------------------------------------------


def test_parse_notification(video_result):
    notification = video_result.parse_notification(rekognition_message())
    assert notification == ("job-123", "SUCCEEDED", UPLOAD_ID)


def test_parse_notification_falls_back_to_job_tag(video_result):
    message = rekognition_message(Video={"S3ObjectName": "unexpected/key.mp4"})
    assert video_result.parse_notification(message).upload_id == UPLOAD_ID


@pytest.mark.parametrize(
    "message",
    [
        "not json",
        json.dumps(["list"]),
        json.dumps({"Status": "SUCCEEDED"}),  # sin JobId
        rekognition_message(JobTag="nope", Video={"S3ObjectName": "other.mp4"}),
    ],
)
def test_parse_notification_rejects_unknown(video_result, message):
    assert video_result.parse_notification(message) is None


def test_aggregate_labels(video_result):
    detections = [
        detection(0, "Beach", 90.0),
        detection(0, "Sky", 80.0),
        detection(500, "Beach", 98.14),
        detection(1000, "Person", 77.7),
        detection(1500, "Beach", 95.0),
        {"Timestamp": 2000, "Label": {}},  # sin nombre: se ignora
    ]

    assert video_result.aggregate_labels(detections) == [
        {"name": "Beach", "confidence": 98.1, "firstSeenMs": 0, "lastSeenMs": 1500, "occurrences": 3},
        {"name": "Sky", "confidence": 80.0, "firstSeenMs": 0, "lastSeenMs": 0, "occurrences": 1},
        {"name": "Person", "confidence": 77.7, "firstSeenMs": 1000, "lastSeenMs": 1000, "occurrences": 1},
    ]


def test_aggregate_labels_handles_unordered_input(video_result):
    labels = video_result.aggregate_labels([detection(3000, "Car", 80), detection(1000, "Car", 85)])
    assert labels[0]["firstSeenMs"] == 1000
    assert labels[0]["lastSeenMs"] == 3000


@pytest.mark.parametrize(
    ("message", "expected"),
    [
        ("Unsupported codec", "unsupported_video_codec"),
        ("The video format is not supported.", "unsupported_video_codec"),
        ("Internal error", "analysis_failed"),
        (None, "analysis_failed"),
    ],
)
def test_classify_failure(video_result, message, expected):
    assert video_result.classify_failure(message) == expected


# --- Handler -----------------------------------------------------------------------------


def test_success_paginates_all_results(video_result):
    pages = [
        {
            "JobStatus": "SUCCEEDED",
            "VideoMetadata": {"DurationMillis": 20700},
            "Labels": [detection(0, "Beach", 90.0), detection(0, "Sky", 85.0)],
            "NextToken": "page-2",
        },
        {
            "JobStatus": "SUCCEEDED",
            "VideoMetadata": {"DurationMillis": 20700},
            "Labels": [detection(20000, "Beach", 98.1)],
        },
    ]
    s3, rekognition = FakeS3(), FakeRekognition(pages=pages)
    install_clients(video_result, s3=s3, rekognition=rekognition)

    video_result.handler(sns_event(rekognition_message()), None)

    calls = [params for name, params in rekognition.calls]
    assert len(calls) == 2
    assert calls[0]["MaxResults"] == 1000
    assert "NextToken" not in calls[0]
    assert calls[1]["NextToken"] == "page-2"

    stored = s3.objects[RESULT_KEY]
    assert stored["ContentType"] == "application/json"
    assert stored["CacheControl"] == "no-store"
    assert s3.json_body(RESULT_KEY) == {
        "status": "SUCCEEDED",
        "kind": "video",
        "durationMs": 20700,
        "labels": [
            {"name": "Beach", "confidence": 98.1, "firstSeenMs": 0, "lastSeenMs": 20000, "occurrences": 2},
            {"name": "Sky", "confidence": 85.0, "firstSeenMs": 0, "lastSeenMs": 0, "occurrences": 1},
        ],
    }


def test_failed_job_with_codec_problem(video_result):
    pages = [{"JobStatus": "FAILED", "StatusMessage": "Unsupported codec/format."}]
    s3 = FakeS3()
    install_clients(video_result, s3=s3, rekognition=FakeRekognition(pages=pages))

    video_result.handler(sns_event(rekognition_message(status="FAILED")), None)

    assert s3.json_body(RESULT_KEY) == {"status": "FAILED", "kind": "video", "error": "unsupported_video_codec"}


def test_failed_job_generic(video_result):
    pages = [{"JobStatus": "FAILED", "StatusMessage": "Something went wrong"}]
    s3 = FakeS3()
    install_clients(video_result, s3=s3, rekognition=FakeRekognition(pages=pages))

    video_result.handler(sns_event(rekognition_message(status="ERROR")), None)

    assert s3.json_body(RESULT_KEY)["error"] == "analysis_failed"


def test_unknown_message_is_ignored(video_result):
    s3, rekognition = FakeS3(), FakeRekognition()
    install_clients(video_result, s3=s3, rekognition=rekognition)

    video_result.handler(sns_event("garbage"), None)

    assert rekognition.calls == []
    assert s3.objects == {}


def test_transient_error_is_raised(video_result):
    class ThrottledRekognition(FakeRekognition):
        def get_label_detection(self, **kwargs):
            raise client_error("ThrottlingException", "GetLabelDetection")

    s3 = FakeS3()
    install_clients(video_result, s3=s3, rekognition=ThrottledRekognition())

    with pytest.raises(Exception):
        video_result.handler(sns_event(rekognition_message()), None)

    assert s3.objects == {}


def test_job_still_in_progress_is_retried(video_result):
    s3 = FakeS3()
    install_clients(video_result, s3=s3, rekognition=FakeRekognition(pages=[{"JobStatus": "IN_PROGRESS"}]))

    with pytest.raises(video_result.TransientError):
        video_result.handler(sns_event(rekognition_message()), None)

    assert s3.objects == {}


def test_unexpected_error_writes_failed(video_result):
    class BrokenRekognition(FakeRekognition):
        def get_label_detection(self, **kwargs):
            raise client_error("ResourceNotFoundException", "GetLabelDetection")

    s3 = FakeS3()
    install_clients(video_result, s3=s3, rekognition=BrokenRekognition())

    video_result.handler(sns_event(rekognition_message()), None)

    assert s3.json_body(RESULT_KEY)["error"] == "processing_failed"
