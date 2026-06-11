from pathlib import Path
from urllib.parse import urlparse
import re


def validate_public_url(raw_url: str) -> None:
    parsed = urlparse(raw_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("Only public http/https URLs are supported.")
    host = parsed.hostname or ""
    blocked_hosts = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
    if host.lower() in blocked_hosts or host.startswith("10.") or host.startswith("192.168."):
        raise ValueError("Private or local URLs are not supported.")


def sanitize_filename(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]+', "_", value).strip(" .")
    return cleaned[:140] or "duck_download"


def ensure_inside(base: Path, target: Path) -> Path:
    resolved_base = base.resolve()
    resolved_target = target.resolve()
    if resolved_base not in resolved_target.parents and resolved_base != resolved_target:
        raise ValueError("Path traversal detected.")
    return resolved_target
