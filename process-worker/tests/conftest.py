"""Loads the worker without pulling Demucs or torch in.

`app.main` imports `app.processor`, which imports torch. Installing a CUDA
stack to test an argument validator is not a trade worth making, so the heavy
module is stubbed before the app is imported. Nothing here touches the
separation itself — what is under test is the contract around it.
"""

from __future__ import annotations

import importlib
import sys
import types
from pathlib import Path

import pytest

_ROOT = Path(__file__).resolve().parents[1]


def _stub_processor() -> None:
    processor = types.ModuleType("app.processor")
    processor.DEFAULT_REMOVE_STEMS = ("drums", "bass", "other")
    processor.STEM_NAMES = ("drums", "bass", "other", "vocals")

    class ProcessResult:
        def __init__(self, output_path, vocals_kept=True, removed_stems=()):
            self.output_path = output_path
            self.vocals_kept = vocals_kept
            self.removed_stems = removed_stems

    processor.ProcessResult = ProcessResult
    processor.probe_duration_seconds = lambda _path: None
    processor.remove_music = lambda *a, **k: ProcessResult(Path("/dev/null"))
    sys.modules["app.processor"] = processor


def _load_main():
    if str(_ROOT) not in sys.path:
        sys.path.insert(0, str(_ROOT))
    package = types.ModuleType("app")
    package.__path__ = [str(_ROOT / "app")]
    sys.modules["app"] = package
    _stub_processor()
    return importlib.import_module("app.main")


main_module = _load_main()


@pytest.fixture()
def worker():
    """The module itself, for the helpers that are not HTTP endpoints."""
    return main_module
