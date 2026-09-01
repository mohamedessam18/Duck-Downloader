"""Reports from users about the ads they were shown.

These do not go to Google. AdMob has its own reporting on the ad itself; this
is the developer's own record, and its whole value is being able to see the
same complaint arrive five times in a week and go block that advertiser in the
AdMob console. A single email would never show that.

Stored as append-only JSONL. A report is a fact that happened at a moment, not
a row to be edited, and an appended line survives a crash mid-write in a way a
rewritten JSON array does not.
"""

from __future__ import annotations

import json
import re
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

# Long enough to describe an ad, short enough that the file cannot be used as
# free storage by anyone who finds the endpoint.
MAX_DETAILS = 2000
MAX_FIELD = 200

# One screenshot, and a ceiling a phone screenshot never reaches. Bigger than
# this is not evidence, it is someone using the endpoint as a disk.
MAX_SCREENSHOT_BYTES = 5 * 1024 * 1024

# Magic bytes, not the Content-Type header. The browser reports whatever the
# file is named, so a .jpg that is really a zip arrives claiming to be an
# image; the first bytes cannot lie about it.
_IMAGE_SIGNATURES: tuple[tuple[bytes, str], ...] = (
    (b"\xff\xd8\xff", "jpg"),
    (b"\x89PNG\r\n\x1a\n", "png"),
    (b"GIF87a", "gif"),
    (b"GIF89a", "gif"),
)

# What a report may be about. Anything else is rejected rather than stored as
# free text, so the reports can be counted by reason without cleaning them up
# first.
REASONS = (
    "sexual",
    "scam",
    "gambling",
    "shocking",
    "malware",
    "age-inappropriate",
    "other",
)

_write_lock = threading.Lock()


def image_extension(data: bytes) -> Optional[str]:
    """The image type these bytes actually are, or None.

    WebP needs its own check because the signature is split: "RIFF", four
    bytes of length, then "WEBP".
    """
    for signature, extension in _IMAGE_SIGNATURES:
        if data.startswith(signature):
            return extension
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def _clean(value: Optional[str], limit: int = MAX_FIELD) -> Optional[str]:
    """Trims a field to something safe to store and read back.

    Control characters are stripped rather than escaped: they have no business
    in any of these fields, and leaving them in makes the log painful to read
    with ordinary tools.
    """
    if value is None:
        return None
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", str(value)).strip()
    if not text:
        return None
    return text[:limit]


def normalise_reason(value: Optional[str]) -> str:
    reason = (value or "").strip().lower()
    return reason if reason in REASONS else "other"


def build_record(
    *,
    reason: Optional[str],
    details: Optional[str],
    ad_format: Optional[str],
    app_version: Optional[str],
    platform: Optional[str],
    locale: Optional[str],
    seen_at: Optional[str],
    screenshot: Optional[str] = None,
) -> dict[str, Any]:
    """Shapes one report.

    Everything here is either chosen by the user or a technical fact about the
    app. Nothing identifies the person: no account, no device id, no IP. A
    report that could be traced back to someone is a liability, and none of it
    would help decide whether to block an advertiser.
    """
    return {
        "id": uuid.uuid4().hex,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "reason": normalise_reason(reason),
        "details": _clean(details, MAX_DETAILS),
        "ad_format": _clean(ad_format, 40),
        "app_version": _clean(app_version, 40),
        "platform": _clean(platform, 80),
        "locale": _clean(locale, 20),
        "seen_at": _clean(seen_at, 40),
        # Filename only. The bytes live next to the log, so a report can be
        # read without loading five megabytes of image with it.
        "screenshot": _clean(screenshot, 80),
    }


def save_screenshot(data: bytes, report_id: str, reports_dir: Path) -> str:
    """Writes one screenshot beside the log and returns its filename.

    Named after the report rather than after whatever the phone called it: an
    uploaded name is attacker-controlled and has no business becoming a path.
    """
    extension = image_extension(data)
    if extension is None:
        raise ValueError("That file is not an image.")
    if len(data) > MAX_SCREENSHOT_BYTES:
        raise ValueError("That image is too large.")

    folder = reports_dir / "screenshots"
    folder.mkdir(parents=True, exist_ok=True)
    filename = f"{report_id}.{extension}"
    (folder / filename).write_bytes(data)
    return filename


def append(record: dict[str, Any], storage_dir: Path) -> None:
    """Appends one report to the log.

    The lock is for two requests arriving together in the same process: two
    interleaved writes would produce one corrupt line, and a corrupt line in
    an append-only log is permanent.
    """
    path = storage_dir / "ad-reports.jsonl"
    line = json.dumps(record, ensure_ascii=False) + "\n"
    with _write_lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)


def summarise(storage_dir: Path, limit: int = 200) -> dict[str, Any]:
    """The most recent reports, and a count per reason.

    The counts are the point: one complaint is noise, the same reason arriving
    thirty times is an advertiser to block.
    """
    path = storage_dir / "ad-reports.jsonl"
    if not path.exists():
        return {"total": 0, "by_reason": {}, "recent": []}

    records: list[dict[str, Any]] = []
    counts: dict[str, int] = {}
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw)
            except json.JSONDecodeError:
                # One unreadable line must not hide every report after it.
                continue
            records.append(record)
            reason = record.get("reason", "other")
            counts[reason] = counts.get(reason, 0) + 1

    return {
        "total": len(records),
        "by_reason": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
        "recent": records[-limit:][::-1],
    }
