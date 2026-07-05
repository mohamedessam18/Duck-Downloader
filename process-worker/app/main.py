"""Duck Downloader AI worker.

A small FastAPI service whose only job is to remove background music from a
media file using Demucs source separation. It reads from the same shared
``/data/downloads`` volume as the main Duck API, so it never has to transfer
files over HTTP: it receives an absolute path, processes it in place, and
writes the cleaned file next to the original.

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

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from .processor import (
    DEFAULT_REMOVE_STEMS,
    ProcessResult,
    probe_duration_seconds,
    remove_music,
)

# Hard limits that protect the GPU from runaway jobs. Overridable via env vars.
MAX_DURATION_SECONDS = float(os.getenv("DUCK_MAX_DURATION_SECONDS", "900"))   # 15 min
MAX_FILE_SIZE_BYTES = int(os.getenv("DUCK_MAX_FILE_SIZE_BYTES", str(600 * 1024 * 1024)))


class ProcessRequest(BaseModel):
    """Payload posted by the main Duck API to start a removal job."""

    input_path: str
    output_format: str = "mp4"
    remove_stems: Optional[tuple[str, ...]] = None


class ProcessResponse(BaseModel):
    """Result returned to the main API."""

    output_path: str
    vocals_kept: bool
    removed_stems: list[str]
    device: str


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
    yield


app = FastAPI(title="Duck Downloader AI Worker", version="1.0.0", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/process", response_model=ProcessResponse)
async def process(body: ProcessRequest) -> ProcessResponse:
    input_path = _resolve_shared_path(body.input_path)
    if not input_path.exists():
        raise HTTPException(status_code=404, detail="Input file not found.")

    size = input_path.stat().st_size
    if size > MAX_FILE_SIZE_BYTES:
        raise HTTPException(
            status_code=413,
            detail="Input file exceeds the maximum allowed size for music removal.",
        )

    duration = probe_duration_seconds(input_path)
    if duration and duration > MAX_DURATION_SECONDS:
        raise HTTPException(
            status_code=413,
            detail="Input media exceeds the maximum allowed duration for music removal.",
        )

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
                remove_music,
                input_path,
                output_path,
                _separate_factory(),
                remove_stems,
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
