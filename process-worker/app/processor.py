"""Music removal processing built on Demucs source separation.

The worker separates a media file into stems (vocals / drums / bass / other),
keeps the vocal (and optionally "other") stems and discards the musical ones,
then re-muxes the result against the original video stream with FFmpeg.

The pure processing functions in this module are intentionally side-effect
free and synchronous so they can be unit tested without a GPU by mocking
``separate_audio`` and ``run_ffmpeg``.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

# Stem names produced by the `htdemucs` 4-source model, in Demucs' order.
STEM_NAMES = ("drums", "bass", "other", "vocals")

# Stems that are considered "music" and get removed. vocals are always kept so
# the speech/dialogue survives. "other" is kept by default because it often
# carries sound effects / ambience that is not music; callers can drop it.
DEFAULT_REMOVE_STEMS = ("drums", "bass")


@dataclass
class ProcessResult:
    """Outcome of a single music-removal job."""

    output_path: Path
    vocals_kept: bool
    removed_stems: tuple[str, ...]


def probe_duration_seconds(media_path: Path) -> float:
    """Return the duration of ``media_path`` in seconds via ffprobe.

    Returns ``0.0`` if ffprobe is unavailable or the value cannot be parsed so
    callers can apply an upper-bound guard without crashing the request.
    """

    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return 0.0
    try:
        completed = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(media_path),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return float(completed.stdout.strip() or 0.0)
    except (subprocess.CalledProcessError, ValueError):
        return 0.0


def run_ffmpeg(args: list[str]) -> subprocess.CompletedProcess:
    """Run an FFmpeg command, raising ``RuntimeError`` with stderr on failure.

    Mirrors the pattern used by ``backend/app/downloads.py::trim`` so error
    messages stay actionable for the main API's ``public_error`` mapping.
    """

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("FFmpeg is not installed on the worker.")
    cmd = [ffmpeg, "-y", *args]
    completed = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        tail = (completed.stderr or "").strip().splitlines()[-6:]
        details = "\n".join(tail).strip()
        raise RuntimeError(details or f"FFmpeg failed with exit code {completed.returncode}.")
    return completed


def extract_audio(video_path: Path, wav_path: Path) -> None:
    """Extract a 44.1 kHz stereo WAV from ``video_path`` for Demucs."""

    run_ffmpeg(["-i", str(video_path), "-vn", "-ac", "2", "-ar", "44100", str(wav_path)])


def mux_without_music(
    video_path: Path,
    new_audio_path: Path,
    output_path: Path,
    *,
    is_audio_only: bool,
) -> None:
    """Combine the original video stream with the cleaned audio track.

    When ``is_audio_only`` is true the result is a re-encoded audio file (the
    original download was an audio extract) and we skip the video stream.
    """

    if is_audio_only:
        run_ffmpeg(["-i", str(new_audio_path), "-b:a", "192k", str(output_path)])
        return
    run_ffmpeg(
        [
            "-i",
            str(video_path),
            "-i",
            str(new_audio_path),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-shortest",
            str(output_path),
        ]
    )


def mix_stems(
    stem_paths: dict[str, Path],
    keep_stems: tuple[str, ...],
    output_path: Path,
) -> None:
    """Mix the kept stems back into a single audio file with FFmpeg.

    Each kept stem is added as an input and all of them are summed with the
    ``amix`` filter. ``keep_stems`` must reference stems present in
    ``stem_paths``.
    """

    available = [name for name in keep_stems if name in stem_paths]
    if not available:
        raise RuntimeError("No stems available to mix after music removal.")

    inputs: list[str] = []
    for name in available:
        inputs.extend(["-i", str(stem_paths[name])])

    filter_parts = [f"[{index}:a]" for index in range(len(available))]
    amix = "".join(filter_parts) + f"amix=inputs={len(available)}:duration=longest:normalize=0"
    run_ffmpeg([*inputs, "-filter_complex", amix, str(output_path)])


def remove_music(
    input_path: Path,
    output_path: Path,
    *,
    separate_audio: Callable[[Path, Path], dict[str, Path]],
    remove_stems: tuple[str, ...] = DEFAULT_REMOVE_STEMS,
) -> ProcessResult:
    """Remove the configured musical stems from ``input_path``.

    ``separate_audio`` is injected so tests can substitute a fake implementation
    without loading Demucs. It receives the source WAV path and a destination
    directory, and must return a mapping of stem name to WAV path. Only the
    stems in ``STEM_NAMES`` are recognised.
    """

    with tempfile.TemporaryDirectory(prefix="duck-music-") as work_dir:
        work = Path(work_dir)
        source_wav = work / "source.wav"
        extract_audio(input_path, source_wav)

        stem_paths = separate_audio(source_wav, work)
        # Normalise to only the stems we know how to reason about.
        stem_paths = {name: path for name, path in stem_paths.items() if name in STEM_NAMES}
        if "vocals" not in stem_paths:
            raise RuntimeError("Source separation did not produce a vocals stem.")

        keep_stems = tuple(name for name in STEM_NAMES if name not in remove_stems)
        cleaned_audio = work / "cleaned.wav"
        mix_stems(stem_paths, keep_stems, cleaned_audio)

        # Detect whether the source is audio-only by extension; the main API
        # only ever sends .mp4 (video) or .mp3 (audio) so this is reliable.
        is_audio_only = input_path.suffix.lower() == ".mp3"
        mux_without_music(input_path, cleaned_audio, output_path, is_audio_only=is_audio_only)

        removed = tuple(name for name in STEM_NAMES if name in remove_stems and name in stem_paths)
        return ProcessResult(
            output_path=output_path,
            vocals_kept=True,
            removed_stems=removed,
        )


__all__ = [
    "DEFAULT_REMOVE_STEMS",
    "ProcessResult",
    "STEM_NAMES",
    "extract_audio",
    "mix_stems",
    "mux_without_music",
    "probe_duration_seconds",
    "remove_music",
    "run_ffmpeg",
]
