"""The contract between the API and the worker.

Demucs is never loaded here. What is under test is everything around it: which
source a request may name, who is allowed to ask, and the size and duration
ceilings that stop one job from taking the GPU down with it.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from conftest import main_module


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setattr(main_module, "WORKER_TOKEN", "")
    return TestClient(main_module.app)


def test_a_request_must_name_exactly_one_source(client):
    # Both, or neither, is a caller that has not decided how it is deploying —
    # and guessing for them is how you get a path sent to a worker on another
    # machine.
    for payload in (
        {},
        {"input_url": "https://x/f.mp4", "input_path": "/data/downloads/f.mp4"},
    ):
        response = client.post("/process/stream", json=payload)
        assert response.status_code == 422, payload


def test_each_endpoint_refuses_the_other_ones_source(client):
    streaming = client.post("/process/stream", json={"input_path": "/data/downloads/f.mp4"})
    assert streaming.status_code == 400
    assert "input_url" in streaming.json()["detail"]

    in_place = client.post("/process", json={"input_url": "https://x/f.mp4"})
    assert in_place.status_code == 400
    assert "input_path" in in_place.json()["detail"]


def test_a_path_outside_the_shared_volume_is_refused(client, monkeypatch):
    monkeypatch.setenv("DUCK_STORAGE_DIR", "/data/downloads")
    response = client.post("/process", json={"input_path": "/etc/passwd"})
    assert response.status_code == 400


def test_only_http_urls_are_fetched(client):
    # file:// would read the worker's own disk, which is the whole thing the
    # shared-path guard exists to prevent.
    response = client.post("/process/stream", json={"input_url": "file:///etc/passwd"})
    assert response.status_code == 400


def test_the_token_is_enforced_when_set(monkeypatch):
    monkeypatch.setattr(main_module, "WORKER_TOKEN", "s3cret")
    client = TestClient(main_module.app)

    refused = client.post("/process/stream", json={"input_url": "https://x/f.mp4"})
    assert refused.status_code == 401

    wrong = client.post(
        "/process/stream",
        json={"input_url": "https://x/f.mp4"},
        headers={"X-Duck-Worker-Token": "nope"},
    )
    assert wrong.status_code == 401


def test_an_oversized_content_length_is_refused_before_the_body_arrives(
    client, monkeypatch, tmp_path
):
    class FakeResponse:
        headers = {"Content-Length": str(main_module.MAX_FILE_SIZE_BYTES + 1)}

        def read(self, _size):
            raise AssertionError("the body must never start downloading")

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    monkeypatch.setattr(main_module.urllib.request, "urlopen", lambda *a, **k: FakeResponse())

    with pytest.raises(main_module.HTTPException) as caught:
        main_module._fetch_input("https://x/f.mp4", tmp_path / "in.mp4")
    assert caught.value.status_code == 413


def test_a_lying_content_length_is_caught_mid_transfer(client, monkeypatch, tmp_path):
    # The header is written by whoever is sending the file, so it is a hint and
    # not a fact. Without the second check a truthful-looking header fills the
    # disk.
    chunk = b"x" * (1024 * 1024)

    class FakeResponse:
        headers = {"Content-Length": "10"}

        def read(self, _size):
            return chunk

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    monkeypatch.setattr(main_module, "MAX_FILE_SIZE_BYTES", 2 * 1024 * 1024)
    monkeypatch.setattr(main_module.urllib.request, "urlopen", lambda *a, **k: FakeResponse())

    with pytest.raises(main_module.HTTPException) as caught:
        main_module._fetch_input("https://x/f.mp4", tmp_path / "in.mp4")
    assert caught.value.status_code == 413


def test_an_empty_download_is_an_error_not_a_silent_success(client, monkeypatch, tmp_path):
    class FakeResponse:
        headers = {}

        def read(self, _size):
            return b""

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    monkeypatch.setattr(main_module.urllib.request, "urlopen", lambda *a, **k: FakeResponse())

    with pytest.raises(main_module.HTTPException) as caught:
        main_module._fetch_input("https://x/f.mp4", tmp_path / "in.mp4")
    assert caught.value.status_code == 502
