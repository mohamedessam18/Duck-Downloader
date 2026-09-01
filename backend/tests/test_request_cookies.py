"""Cookies must belong to one request and one user, and nothing else.

The bug these guard against: the server used to keep a single cookies.txt that
every download read and any caller could overwrite. One user's Instagram
session became the default credentials for the next user's download, and was
itself replaced by whoever logged in after them.
"""

from __future__ import annotations

import asyncio
import os
import stat
from pathlib import Path

import pytest

from backend.app import cookies
from backend.app.config import settings
from backend.app.downloads import DownloadManager, DownloadState
from backend.app.models import DownloadType

VALID = ".instagram.com\tTRUE\t/\tTRUE\t1799999999\tsessionid\tabc123"


@pytest.fixture(autouse=True)
def _restore_event_loop():
    """Leave a usable event loop behind for whatever test module runs next.

    `asyncio.run` closes the loop it created and installs nothing in its place.
    On Python 3.9 `DownloadManager()` builds an `asyncio.Semaphore`, which asks
    for the current loop at construction, so a later module that makes one from
    synchronous test code would fail purely because this one ran first.
    """
    yield
    asyncio.set_event_loop(asyncio.new_event_loop())


def test_keeps_a_well_formed_line():
    out = cookies.sanitise(VALID)
    assert out.startswith("# Netscape HTTP Cookie File\n")
    assert VALID in out


def test_rebuilds_rather_than_passes_through():
    # Lowercase flags are legal input and must come back normalised, which is
    # only possible if the line was parsed field by field instead of copied.
    out = cookies.sanitise(".x.com\ttrue\t/\tfalse\t17\tauth_token\tv")
    assert ".x.com\tTRUE\t/\tFALSE\t17\tauth_token\tv" in out


def test_drops_lines_that_are_not_seven_fields():
    assert cookies.sanitise("not a cookie file at all") == ""
    assert cookies.sanitise(".x.com\tTRUE\t/\tTRUE\t17\tname") == ""
    assert cookies.sanitise(".x.com\tTRUE\t/\tTRUE\t17\tname\tv\textra") == ""


def test_drops_comments_but_keeps_httponly_cookies():
    out = cookies.sanitise(
        "# a comment\n"
        "#HttpOnly_.facebook.com\tTRUE\t/\tTRUE\t9\tc_user\t1"
    )
    assert "a comment" not in out
    assert "#HttpOnly_.facebook.com\tTRUE\t/\tTRUE\t9\tc_user\t1" in out


@pytest.mark.parametrize(
    "line",
    [
        # A domain that is really a path, which is what an attempt to steer the
        # file somewhere else would look like.
        "../../etc/passwd\tTRUE\t/\tTRUE\t9\ta\tb",
        "in stagram.com\tTRUE\t/\tTRUE\t9\ta\tb",
        # A newline smuggled into a value would forge a second cookie line.
        ".x.com\tTRUE\t/\tTRUE\t9\ta\tb\x00c",
        # Path must be a path.
        ".x.com\tTRUE\tnope\tTRUE\t9\ta\tb",
        # Expiry must be a number, not a word yt-dlp would choke on.
        ".x.com\tTRUE\t/\tTRUE\tsoon\ta\tb",
        # Names cannot carry the separators that end a cookie.
        ".x.com\tTRUE\t/\tTRUE\t9\ta=b\tc",
        ".x.com\tTRUE\t/\tTRUE\t9\ta;b\tc",
        # Flags are a two-value field, not free text.
        ".x.com\tMAYBE\t/\tTRUE\t9\ta\tb",
    ],
)
def test_refuses_malformed_fields(line):
    assert cookies.sanitise(line) == ""


def test_refuses_an_oversized_payload():
    with pytest.raises(ValueError):
        cookies.sanitise("x" * (cookies.MAX_COOKIES_BYTES + 1))


def test_caps_the_number_of_cookies():
    many = "\n".join(
        f".x.com\tTRUE\t/\tTRUE\t9\tname{i}\tv" for i in range(cookies.MAX_COOKIE_LINES + 50)
    )
    kept = cookies.sanitise(many).strip().splitlines()[1:]
    assert len(kept) == cookies.MAX_COOKIE_LINES


def test_empty_input_means_no_cookies_not_an_empty_jar():
    assert cookies.sanitise(None) == ""
    assert cookies.sanitise("") == ""
    assert cookies.sanitise("# Netscape HTTP Cookie File\n") == ""


def test_scoped_writes_then_deletes_the_file():
    with cookies.scoped(VALID) as path:
        assert path is not None
        written = Path(path)
        assert written.exists()
        assert VALID in written.read_text()
        assert cookies.active_cookies_file() == path
    assert not written.exists()


def test_scoped_file_is_not_readable_by_others():
    with cookies.scoped(VALID) as path:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    # A session in a world-readable temp file is a session anyone on the host
    # can take.
    assert mode & (stat.S_IRGRP | stat.S_IROTH | stat.S_IWGRP | stat.S_IWOTH) == 0


def test_scoped_stores_the_sanitised_text_not_the_input():
    with cookies.scoped(f"{VALID}\njunk line\n") as path:
        body = Path(path).read_text()
    assert "junk line" not in body


def test_no_cookies_means_no_cookies():
    with cookies.scoped(None) as path:
        assert path is None
        assert cookies.active_cookies_file() is None


def test_falls_back_to_the_operator_file_only():
    settings.cookies_file = "/etc/duck/operator-cookies.txt"
    try:
        assert cookies.active_cookies_file() == "/etc/duck/operator-cookies.txt"
        with cookies.scoped(VALID) as path:
            # The caller's own cookies win while their request is running.
            assert cookies.active_cookies_file() == path
        assert cookies.active_cookies_file() == "/etc/duck/operator-cookies.txt"
    finally:
        settings.cookies_file = None


def test_a_dropped_file_in_storage_is_never_picked_up():
    # The exact shape of the old bug: anything that lands at this path used to
    # become everybody's credentials.
    planted = settings.storage_dir / "cookies.txt"
    planted.parent.mkdir(parents=True, exist_ok=True)
    planted.write_text(VALID)
    try:
        assert settings.resolved_cookies_file is None
        assert cookies.active_cookies_file() is None
    finally:
        planted.unlink(missing_ok=True)


def test_two_requests_never_see_each_others_cookies():
    seen: dict[str, str | None] = {}
    started = asyncio.Event()

    async def one(name: str, text: str, wait: bool) -> None:
        with cookies.scoped(text):
            if wait:
                started.set()
                await asyncio.sleep(0.05)
            else:
                await started.wait()
            path = cookies.active_cookies_file()
            seen[name] = Path(path).read_text() if path else None

    async def both() -> None:
        await asyncio.gather(
            one("a", VALID, wait=True),
            one("b", ".x.com\tTRUE\t/\tTRUE\t9\tauth_token\tsecret-b", wait=False),
        )

    asyncio.run(both())
    assert "sessionid" in seen["a"] and "auth_token" not in seen["a"]
    assert "auth_token" in seen["b"] and "sessionid" not in seen["b"]


def test_a_request_without_cookies_cannot_inherit_a_live_one():
    async def holder() -> None:
        with cookies.scoped(VALID):
            await asyncio.sleep(0.05)

    async def bare() -> str | None:
        await asyncio.sleep(0.01)
        return cookies.active_cookies_file()

    async def both() -> str | None:
        _, got = await asyncio.gather(holder(), bare())
        return got

    assert asyncio.run(both()) is None


async def _queue_one(cookies_text: str | None) -> tuple[DownloadManager, DownloadState]:
    """Queue a download and stop its task before it can reach the network."""
    manager = DownloadManager()
    download_id = await manager.start(
        "https://example.com/v", DownloadType.video, "Best", cookies=cookies_text
    )
    task = manager.tasks.pop(download_id, None)
    if task is not None:
        task.cancel()
    return manager, manager.states[download_id]


def test_download_keeps_its_own_cookie_file_then_discards_it():
    manager, state = asyncio.run(_queue_one(VALID))

    assert state.cookies_path is not None
    path = Path(state.cookies_path)
    assert path.exists() and VALID in path.read_text()

    manager._discard_cookies(state)
    assert not path.exists()
    assert state.cookies_path is None
    # Idempotent: the finally block and an earlier cancel can both reach it.
    manager._discard_cookies(state)


def test_download_without_cookies_holds_no_file():
    _, state = asyncio.run(_queue_one(None))
    assert state.cookies_path is None


def test_state_binding_is_what_the_task_reads():
    state = DownloadState("id", "u", DownloadType.video, "Best", False, cookies_path="/tmp/x")
    token = cookies.bind(state.cookies_path)
    try:
        assert cookies.active_cookies_file() == "/tmp/x"
    finally:
        cookies.unbind(token)
    assert cookies.active_cookies_file() is None


def test_ytdlp_options_use_the_scoped_file(tmp_path):
    """The wiring that matters: a request's cookies reach yt-dlp itself."""
    manager = DownloadManager.__new__(DownloadManager)
    with cookies.scoped(VALID) as path:
        opts = DownloadManager._base_ydl_options(manager, skip_download=True)
    assert opts["cookiefile"] == path


def test_ytdlp_args_use_the_scoped_file(tmp_path):
    manager = DownloadManager.__new__(DownloadManager)
    state = DownloadState("id", "https://x.com/a/status/1", DownloadType.video, "Best", False)
    with cookies.scoped(VALID) as path:
        args = DownloadManager._build_ytdlp_args(
            manager,
            state=state,
            target_dir=tmp_path,
            download_type=DownloadType.video,
            quality="Best",
            prefer_tiktok_no_watermark=False,
        )
    assert "--cookies" in args
    assert args[args.index("--cookies") + 1] == path


def test_ytdlp_gets_no_cookies_when_the_request_sent_none(tmp_path):
    manager = DownloadManager.__new__(DownloadManager)
    state = DownloadState("id", "https://x.com/a/status/1", DownloadType.video, "Best", False)
    args = DownloadManager._build_ytdlp_args(
        manager,
        state=state,
        target_dir=tmp_path,
        download_type=DownloadType.video,
        quality="Best",
        prefer_tiktok_no_watermark=False,
    )
    assert "--cookies" not in args
    assert "cookiefile" not in DownloadManager._base_ydl_options(manager, skip_download=True)
