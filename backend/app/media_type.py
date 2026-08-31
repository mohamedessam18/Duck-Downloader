"""Deciding what kind of media a link points at.

Pure string work, kept out of ``downloads.py`` so it can be tested without
loading a video extractor — and because "is this a picture?" is a question
that has nothing to do with how anything gets downloaded.
"""

from __future__ import annotations

from pathlib import PurePosixPath
from typing import Optional

# Extensions the app treats as a still image.
IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"})


def direct_image_extension(url_path: str) -> Optional[str]:
    """The image extension this URL *path* ends with, if any.

    The path only — never the query string. This used to search the whole URL
    for ".jpg" and friends, so every video link carrying a thumbnail parameter
    came back as a picture:

        /watch?v=abc&thumb=cover.jpg  ->  "Original Image"

    A substring match was wrong twice over: it read the query, and it matched
    inside words, so "/.gifted/video" was a GIF.
    """
    suffix = PurePosixPath(url_path).suffix.lower()
    return suffix.lstrip(".") if suffix in IMAGE_EXTENSIONS else None


# What yt-dlp says when it found media it could not fetch, as opposed to
# finding none at all.
#
# Every entry is a whole phrase, not a word. A bare "age" matches "page" and
# "message"; a bare "bot" matches "about" and "robot" — which is how "There is
# no video on this page" was read as "this video is age-restricted".
_MEDIA_EXISTS_MARKERS = (
    "sign in",
    "log in",
    "login required",
    "is private",
    "private video",
    "forbidden",
    "http error 403",
    "http error 429",
    "too many requests",
    "age-restricted",
    "age restricted",
    "confirm your age",
    "members-only",
    "members only",
    "premieres in",
    "live event will begin",
    "not available in your country",
    "geo-restricted",
    "geo restricted",
    "unable to download video data",
    "not a bot",
    "captcha",
    "cookies",
    "requested format is not available",
)


def failure_means_no_video(error: BaseException) -> bool:
    """Whether this failure means the page simply has no video on it.

    Decides whether falling back to scraping the page for images is honest.
    A link that yt-dlp recognised and then could not fetch — private,
    age-gated, blocked, rate-limited — *is* a video, and answering with a
    picture off the page hands the user the wrong file and buries the reason.
    """
    message = str(error).lower()
    return not any(marker in message for marker in _MEDIA_EXISTS_MARKERS)
