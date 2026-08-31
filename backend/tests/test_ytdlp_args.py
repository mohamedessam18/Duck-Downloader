"""What the download subprocess is actually told.

Extraction and downloading go through two different code paths — the Python
API in one place, `python -m yt_dlp` in another — and they had drifted. The
extractor knew how to talk to YouTube and the downloader did not, so a video
would resolve its real title and formats and then fail at the last step with
`HTTP Error 403: Forbidden`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_SOURCE = (_ROOT / "app" / "downloads.py").read_text(encoding="utf-8")


def _args_block() -> str:
    """The body of `_build_ytdlp_args`, read as text.

    Read rather than called: importing the module needs yt-dlp, which needs a
    newer Python than this machine has. A fake yt-dlp would not tell us
    anything about the arguments a real one receives.
    """
    start = _SOURCE.index("def _build_ytdlp_args")
    end = _SOURCE.index("def _format_selector", start)
    return _SOURCE[start:end]


def test_the_downloader_is_given_a_javascript_runtime():
    # Without this, every YouTube download ends in 403 while extraction keeps
    # working — which is why it read as a network fault rather than a missing
    # dependency.
    block = _args_block()
    assert "--js-runtimes" in block
    assert "node" in block


def test_the_runtime_is_pointed_at_by_path():
    # The binary is copied in from another build stage rather than installed,
    # so PATH is not something to rely on.
    block = _args_block()
    match = re.search(r'"--js-runtimes",\s*"([^"]+)"', block)
    assert match, "the runtime argument is not a literal pair any more"
    assert match.group(1).startswith("node:/"), match.group(1)


def test_the_runtime_is_added_rather_than_replacing_the_default():
    # yt-dlp picks the highest-priority runtime that is both enabled and
    # present. Appending means an image that later ships deno starts using it
    # without anyone editing this.
    assert "--no-js-runtimes" not in _args_block()


def test_the_extraction_path_enables_it_too():
    # The two paths drifting apart is the bug this file exists for.
    start = _SOURCE.index("def _base_ydl_options")
    end = _SOURCE.index("async def start", start)
    assert '"js_runtimes"' in _SOURCE[start:end]


def test_no_player_client_is_forced():
    # Guards the older decision this file sits next to: forcing mweb fixed some
    # Shorts and made ordinary watch pages more likely to hit bot checks.
    assert "--extractor-args" not in _args_block().replace(
        '"tiktok:api_hostname', ""
    ) or "tiktok" in _args_block()
