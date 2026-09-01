"""Per-request cookies, so one user's session never rides on another's request.

This module exists because of a specific bug. The app used to POST the cookies
it harvested from its in-app browser to `/api/cookies`, and the server wrote
them to a single file — `storage_dir/cookies.txt` — that every later yt-dlp
invocation read. On a shared deployment that is not a cache, it is a session
store with one slot: the last person to log in donated their Instagram or
YouTube session to whoever downloaded next, and their own session was in turn
overwritten by the next person to log in.

The fix is that cookies never come to rest on the server. The app keeps them on
the device, sends only the ones belonging to the link being fetched, and the
server writes them to a private file for exactly as long as the request or the
download that needs them, then deletes it.

`settings.cookies_file` — the operator's own cookies, set by environment
variable — is still honoured as a fallback. That one is deliberate
configuration by whoever runs the server, not a stranger's login.
"""

from __future__ import annotations

import os
import re
import tempfile
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from typing import Iterator

from .config import settings

# A cookie jar for one post is a few hundred bytes; a session for a large
# account is a few kilobytes. Anything past this is not a cookie file, and
# accepting it would let a caller write an arbitrarily large file per request.
MAX_COOKIES_BYTES = 512 * 1024

# Netscape files are one cookie per line. A real jar for a single site is tens
# of lines; this leaves room for every host a login touches and still bounds
# the work done per request.
MAX_COOKIE_LINES = 2000

_HEADER = "# Netscape HTTP Cookie File\n"

# curl and yt-dlp mark HttpOnly cookies with this prefix on the domain field.
# It looks like a comment and has to be kept, not stripped as one.
_HTTP_ONLY_PREFIX = "#HttpOnly_"

_DOMAIN_RE = re.compile(r"^\.?[A-Za-z0-9]([A-Za-z0-9.\-_]*[A-Za-z0-9])?$")
_NAME_RE = re.compile(r"^[^\x00-\x20;,=\x7f]+$")
_VALUE_RE = re.compile(r"^[^\x00-\x1f\x7f]*$")
_EXPIRY_RE = re.compile(r"^\d{1,19}$")

_active_cookies_file: ContextVar[str | None] = ContextVar(
    "duck_active_cookies_file", default=None
)


def sanitise(text: str | None) -> str:
    """Rewrite `text` as a Netscape cookie file containing only valid lines.

    The point is not politeness about malformed input. Whatever arrives here
    came over the network and is about to be handed to yt-dlp as a file, so it
    is rebuilt field by field rather than trusted and written through. A line
    that does not parse as seven well-formed tab-separated fields is dropped,
    not repaired.

    Returns an empty string when nothing survives, which callers read as
    "this request has no cookies" rather than as an empty jar.
    """
    if not text:
        return ""
    if len(text.encode("utf-8", "ignore")) > MAX_COOKIES_BYTES:
        raise ValueError("Cookies payload is too large.")

    kept: list[str] = []
    for raw in text.splitlines():
        if len(kept) >= MAX_COOKIE_LINES:
            break
        line = raw.rstrip("\r")
        if not line.strip():
            continue

        http_only = line.startswith(_HTTP_ONLY_PREFIX)
        if http_only:
            line = line[len(_HTTP_ONLY_PREFIX):]
        elif line.lstrip().startswith("#"):
            continue

        fields = line.split("\t")
        if len(fields) != 7:
            continue
        domain, include_subdomains, path, secure, expiry, name, value = fields

        if not _DOMAIN_RE.match(domain):
            continue
        if include_subdomains.upper() not in {"TRUE", "FALSE"}:
            continue
        if not path.startswith("/") or not _VALUE_RE.match(path):
            continue
        if secure.upper() not in {"TRUE", "FALSE"}:
            continue
        if not _EXPIRY_RE.match(expiry):
            continue
        if not _NAME_RE.match(name) or not _VALUE_RE.match(value):
            continue

        prefix = _HTTP_ONLY_PREFIX if http_only else ""
        kept.append(
            "\t".join(
                [
                    prefix + domain,
                    include_subdomains.upper(),
                    path,
                    secure.upper(),
                    expiry,
                    name,
                    value,
                ]
            )
        )

    if not kept:
        return ""
    return _HEADER + "\n".join(kept) + "\n"


def write_cookie_file(text: str) -> Path:
    """Write sanitised cookie text to a file only this process can read.

    Mode 0600 from the moment it exists: `mkstemp` creates it that way, so
    there is no window where another account on the host could read someone's
    session out of the temp directory.
    """
    handle, name = tempfile.mkstemp(prefix="duck-cookies-", suffix=".txt")
    path = Path(name)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return path


def active_cookies_file() -> str | None:
    """The cookie file the current request or download is allowed to use.

    Every yt-dlp call site reads this instead of `settings.resolved_cookies_file`
    so that a caller who sent no cookies cannot pick up someone else's.
    """
    scoped = _active_cookies_file.get()
    if scoped:
        return scoped
    return settings.resolved_cookies_file


def bind(path: str | None):
    """Make `path` the active cookie file for this context. Returns a token."""
    return _active_cookies_file.set(path)


def unbind(token) -> None:
    _active_cookies_file.reset(token)


@contextmanager
def scoped(text: str | None) -> Iterator[str | None]:
    """Bind `text` as this context's cookies, then delete the file.

    Use around a single request. Downloads outlive their request and bind the
    file themselves — see `DownloadManager._download`.
    """
    cleaned = sanitise(text)
    if not cleaned:
        yield None
        return
    path = write_cookie_file(cleaned)
    token = bind(str(path))
    try:
        yield str(path)
    finally:
        unbind(token)
        path.unlink(missing_ok=True)
