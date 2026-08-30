"""Duck Downloader AI worker.

A small FastAPI service whose only job is to remove background music from a
media file using Demucs source separation.

It accepts work two ways:

``input_url``
    Fetch the file over HTTP, process it, and stream the result back in the
    response body. Nothing is shared between the two services, so the worker
    can live wherever there is a GPU while the API stays where it is.

``input_path``
    Read a path on a volume both services mount, process it in place. Only
    usable when they run on the same host, which is what ``docker-compose``
    does for local work.

The path mode was the only one that existed, and it quietly required the API
and the GPU to be the same machine — so deploying the worker anywhere with a
graphics card meant moving the whole API onto a GPU host and paying for a card
to serve JSON.

Concurrency is intentionally serial (a single asyncio lock) because Demucs is
GPU/RAM heavy. The main API controls admission via its download semaphore and
rate limiter; this lock is the last line of defence for the worker itself.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

import urllib.error
import urllib.parse
import urllib.request

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask
from pydantic import BaseModel, model_validator

from .processor import (
    DEFAULT_REMOVE_STEMS,
    ProcessResult,
    probe_duration_seconds,
    remove_music,
)

# Hard limits that protect the GPU from runaway jobs. Overridable via env vars.
MAX_DURATION_SECONDS = float(os.getenv("DUCK_MAX_DURATION_SECONDS", "900"))   # 15 min
MAX_FILE_SIZE_BYTES = int(os.getenv("DUCK_MAX_FILE_SIZE_BYTES", str(600 * 1024 * 1024)))

# Shared secret with the main API.
#
# Once the worker is reachable over the internet rather than sitting on the
# API's own host, an open /process endpoint is a free GPU for anyone who finds
# it. Enforced whenever it is set; the startup hook below complains loudly when
# it is not.
WORKER_TOKEN = os.getenv("DUCK_WORKER_TOKEN", "").strip()

# How long to wait on the API while pulling the input file.
FETCH_TIMEOUT_SECONDS = float(os.getenv("DUCK_WORKER_FETCH_TIMEOUT", "120"))


class ProcessRequest(BaseModel):
    """Payload posted by the main Duck API to start a removal job.

    Exactly one of ``input_url`` and ``input_path`` is required.
    """

    input_url: Optional[str] = None
    input_path: Optional[str] = None
    output_format: str = "mp4"
    remove_stems: Optional[tuple[str, ...]] = None

    @model_validator(mode="after")
    def _exactly_one_source(self) -> "ProcessRequest":
        if bool(self.input_url) == bool(self.input_path):
            raise ValueError("Provide exactly one of input_url or input_path.")
        return self


class ProcessResponse(BaseModel):
    """Result returned to the main API."""

    output_path: str
    vocals_kept: bool
    removed_stems: list[str]
    device: str



def _warn_if_unprotected() -> None:
    if WORKER_TOKEN:
        return
    print(
        "WARNING: DUCK_WORKER_TOKEN is unset. /process and /process/stream will "
        "accept work from anyone who can reach this service. Set it on the "
        "worker and on the API before exposing this to the internet.",
        flush=True,
    )


state: dict[str, Any] = {"separators": None}
# Serialise processing: a single Demucs run saturates the GPU.
_processing_lock = asyncio.Lock()


def _resolve_shared_path(raw_path: str) -> Path:
    """Resolve ``raw_path`` and verify it lives under the shared storage root.

    The worker and the main API share ``DUCK_STORAGE_DIR`` on the host, so the
    path passed in must point inside it. This mirrors the main API's
    ``ensure_inside`` guard and prevents the worker from touching arbitrary
    files on the machine.
    """

    storage_root = Path(os.getenv("DUCK_STORAGE_DIR", "/data/downloads"))
    resolved = Path(raw_path).resolve()
    try:
        resolved.relative_to(storage_root.resolve())
    except ValueError as exc:
        raise HTTPException(
            status_code=400,
            detail="Input path is outside the shared storage volume.",
        ) from exc
    return resolved


def _load_separators() -> dict[str, Any]:
    """Lazily build the Demucs separators on first use.

    Importing torch / demucs is expensive and only happens once per process.
    We keep the model resident for the lifetime of the worker so subsequent
    requests skip the multi-second load. If CUDA is unavailable we fall back
    to CPU automatically and report it back in the response.
    """

    cached = state.get("separators")
    if cached is not None:
        return cached

    try:
        import torch
        from demucs.pretrained import get_model
    except ImportError as exc:  # pragma: no cover - exercised in CI via mocking
        raise HTTPException(
            status_code=500,
            detail="Demucs / torch is not installed on the worker.",
        ) from exc

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = get_model("htdemucs")
    model.to(device)
    separators = {"model": model, "device": device}
    state["separators"] = separators
    return separators


def _separate_with_demucs(model: Any, device: str, source_wav: Path, out_dir: Path) -> dict[str, Path]:
    """Run Demucs on ``source_wav`` and write one WAV per stem to ``out_dir``.

    Returns a mapping of stem name -> path. Demucs emits sources in a fixed
    order (drums, bass, other, vocals) which we rely on in ``processor.py``.
    """

    import torch
    import torchaudio  # local import keeps startup fast for /health
    from demucs.apply import apply_model

    waveform, sample_rate = torchaudio.load(str(source_wav))
    # Demucs expects a batched (batch, channels, samples) tensor.
    batched = waveform.unsqueeze(0)
    with torch.no_grad() if device == "cuda" else _noop():
        estimates = apply_model(model, batched, split=True, overlap=0.25, progress=False)[0]

    stem_paths: dict[str, Path] = {}
    for index, name in enumerate(("drums", "bass", "other", "vocals")):
        stem_path = out_dir / f"{name}.wav"
        torchaudio.save(str(stem_path), estimates[index], sample_rate)
        stem_paths[name] = stem_path
    return stem_paths


class _noop:
    """A ``nullcontext``-style stand-in so we only import torch once."""

    def __enter__(self) -> None:
        return None

    def __exit__(self, *exc_info: object) -> None:
        return None


def _separate_factory():
    """Build the separator callable expected by ``processor.remove_music``.

    This indirection lets the processor stay free of torch/demucs imports so it
    can be unit-tested in isolation.
    """

    def separate(source_wav: Path, out_dir: Path) -> dict[str, Path]:
        separators = _load_separators()
        return _separate_with_demucs(
            separators["model"], separators["device"], source_wav, out_dir
        )

    return separate


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # We deliberately do NOT pre-load the model here: /health must return
    # instantly and the model is heavy. It loads on first /process instead.
    _warn_if_unprotected()
    yield


app = FastAPI(title="Duck Downloader AI Worker", version="1.0.0", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}



def _require_token(provided: Optional[str]) -> None:
    """Rejects work from anyone who does not hold the shared secret."""
    if not WORKER_TOKEN:
        return
    if provided != WORKER_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid worker token.")


def _fetch_input(url: str, destination: Path) -> None:
    """Pulls the file to process into ``destination``.

    Size is checked twice on purpose: ``Content-Length`` is a hint the sender
    controls, so it is also enforced while the bytes arrive. Otherwise a
    truthful-looking header would let a 5GB file fill the disk before anyone
    noticed.
    """

    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="Input URL must be http(s).")

    request = urllib.request.Request(url, headers={"User-Agent": "duck-worker"})
    try:
        with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
            declared = response.headers.get("Content-Length")
            if declared and int(declared) > MAX_FILE_SIZE_BYTES:
                raise HTTPException(
                    status_code=413,
                    detail="Input file exceeds the maximum allowed size for music removal.",
                )

            written = 0
            with destination.open("wb") as out:
                while chunk := response.read(1024 * 1024):
                    written += len(chunk)
                    if written > MAX_FILE_SIZE_BYTES:
                        raise HTTPException(
                            status_code=413,
                            detail="Input file exceeds the maximum allowed size for music removal.",
                        )
                    out.write(chunk)
    except HTTPException:
        raise
    except urllib.error.HTTPError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Could not fetch the input file ({exc.code}).",
        ) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Could not fetch the input file: {exc}",
        ) from exc

    if written == 0:
        raise HTTPException(status_code=502, detail="The input file was empty.")


def _guard_duration(path: Path) -> None:
    duration = probe_duration_seconds(path)
    if duration and duration > MAX_DURATION_SECONDS:
        raise HTTPException(
            status_code=413,
            detail="Input media exceeds the maximum allowed duration for music removal.",
        )


def _separate(input_path: Path, output_path: Path, remove_stems: tuple[str, ...]) -> ProcessResult:
    return remove_music(
        input_path,
        output_path,
        _separate_factory(),
        remove_stems,
    )


@app.post("/process", response_model=ProcessResponse)
async def process(
    body: ProcessRequest,
    x_duck_worker_token: Optional[str] = Header(default=None),
) -> ProcessResponse:
    """Removes the music from a file the API already holds, in place.

    Same-host mode. The response says where the file is, because it never
    moved: the worker overwrote the original on the volume both services see.
    """

    _require_token(x_duck_worker_token)
    if not body.input_path:
        raise HTTPException(
            status_code=400,
            detail="This endpoint takes input_path. Use /process/stream for a URL.",
        )

    input_path = _resolve_shared_path(body.input_path)
    if not input_path.exists():
        raise HTTPException(status_code=404, detail="Input file not found.")

    if input_path.stat().st_size > MAX_FILE_SIZE_BYTES:
        raise HTTPException(
            status_code=413,
            detail="Input file exceeds the maximum allowed size for music removal.",
        )
    _guard_duration(input_path)

    # Write into a sibling temp file then atomically replace the original so a
    # half-written file is never visible to the StaticFiles server / clients.
    stem = input_path.stem
    ext = ".mp3" if body.output_format == "mp3" else ".mp4"
    suffix = input_path.suffix or ext
    out_ext = ext if body.output_format in {"mp3", "mp4"} else suffix
    temp_dir = Path(tempfile.mkdtemp(prefix="duck-out-", dir=str(input_path.parent)))
    output_path = temp_dir / f"{stem}_nomusic{out_ext}"

    remove_stems = tuple(body.remove_stems) if body.remove_stems else DEFAULT_REMOVE_STEMS

    async with _processing_lock:
        try:
            result: ProcessResult = await asyncio.to_thread(
                _separate, input_path, output_path, remove_stems
            )
        except Exception as exc:  # surfaced to the main API's public_error mapping
            shutil.rmtree(temp_dir, ignore_errors=True)
            raise HTTPException(status_code=422, detail=str(exc) or "Music removal failed.") from exc

    # Replace the original atomically; the main API keeps state.filename stable.
    backup_path = temp_dir / input_path.name
    shutil.move(str(input_path), str(backup_path))
    shutil.move(str(result.output_path), str(input_path))
    shutil.rmtree(temp_dir, ignore_errors=True)

    device = state.get("separators", {}).get("device", "cpu")
    return ProcessResponse(
        output_path=str(input_path),
        vocals_kept=result.vocals_kept,
        removed_stems=list(result.removed_stems),
        device=device,
    )


@app.post("/process/stream")
async def process_stream(
    body: ProcessRequest,
    x_duck_worker_token: Optional[str] = Header(default=None),
):
    """Fetches the file, removes the music, and streams the result back.

    This is the mode that lets the worker live on its own machine. Nothing is
    shared: the input arrives over HTTP and the output leaves the same way, so
    the only thing the API and the GPU have in common is a URL.

    The temp directory is cleaned by a background task rather than a `finally`,
    because the response body is still being read when this function returns.
    """

    _require_token(x_duck_worker_token)
    if not body.input_url:
        raise HTTPException(
            status_code=400,
            detail="This endpoint takes input_url. Use /process for a shared path.",
        )

    ext = ".mp3" if body.output_format == "mp3" else ".mp4"
    work_dir = Path(tempfile.mkdtemp(prefix="duck-stream-"))
    try:
        source = work_dir / f"input{ext}"
        _fetch_input(body.input_url, source)
        _guard_duration(source)

        output_path = work_dir / f"output{ext}"
        remove_stems = (
            tuple(body.remove_stems) if body.remove_stems else DEFAULT_REMOVE_STEMS
        )

        async with _processing_lock:
            try:
                result: ProcessResult = await asyncio.to_thread(
                    _separate, source, output_path, remove_stems
                )
            except Exception as exc:
                raise HTTPException(
                    status_code=422,
                    detail=str(exc) or "Music removal failed.",
                ) from exc
    except BaseException:
        shutil.rmtree(work_dir, ignore_errors=True)
        raise

    device = state.get("separators", {}).get("device", "cpu")
    return FileResponse(
        path=result.output_path,
        media_type="audio/mpeg" if body.output_format == "mp3" else "video/mp4",
        filename=f"nomusic{ext}",
        headers={
            # The API has no other way to learn what actually happened, since
            # the body is the file rather than JSON.
            "X-Duck-Device": device,
            "X-Duck-Removed-Stems": ",".join(result.removed_stems),
            "X-Duck-Vocals-Kept": "1" if result.vocals_kept else "0",
        },
        background=BackgroundTask(shutil.rmtree, work_dir, ignore_errors=True),
    )
