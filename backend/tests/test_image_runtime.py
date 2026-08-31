"""The container must ship a JavaScript runtime yt-dlp will actually accept.

This is a silent failure, which is what makes it worth a test. A too-old node
is *found* by yt-dlp, rejected for its version, and then quietly swapped for
the JS-less YouTube client — extraction keeps working, so nothing looks wrong
until the download itself comes back `HTTP Error 403: Forbidden`.
"""

from __future__ import annotations

import re
from pathlib import Path

_DOCKERFILE = (Path(__file__).resolve().parents[1] / "Dockerfile").read_text(
    encoding="utf-8"
)

# yt_dlp/utils/_jsruntime.py: NodeJsRuntime.MIN_SUPPORTED_VERSION
_MIN_NODE_MAJOR = 22


def _node_major() -> int:
    match = re.search(r"FROM\s+node:(\d+)", _DOCKERFILE)
    assert match, "the build no longer starts from a node image"
    return int(match.group(1))


def test_node_is_new_enough_for_yt_dlp():
    assert _node_major() >= _MIN_NODE_MAJOR, (
        f"node {_node_major()} is below yt-dlp's minimum of {_MIN_NODE_MAJOR}; "
        "yt-dlp will fall back to its JS-less client and every YouTube "
        "download will fail with 403"
    )


def test_the_node_binary_is_carried_into_the_final_image():
    # It is built in an earlier stage. If the copy is dropped, the PO token
    # provider dies at startup and the JS runtime disappears with it.
    assert "COPY --from=pot-provider /usr/local/bin/node /usr/local/bin/node" in _DOCKERFILE


def test_the_path_the_app_points_at_is_the_path_node_is_copied_to():
    # downloads.py passes `--js-runtimes node:/usr/local/bin/node`. If either
    # side moves, yt-dlp looks somewhere empty and says nothing useful.
    downloads = (Path(__file__).resolve().parents[1] / "app" / "downloads.py").read_text(
        encoding="utf-8"
    )
    match = re.search(r'"--js-runtimes",\s*"node:([^"]+)"', downloads)
    assert match, "the runtime argument is gone from the download command"
    assert f"/usr/local/bin/node {match.group(1)}" in _DOCKERFILE.replace(
        "COPY --from=pot-provider ", ""
    ) or match.group(1) == "/usr/local/bin/node"
