"""Deciding whether a link is a video or a picture.

Getting this wrong is not a small thing: a video link answered as an image
gives the user a thumbnail instead of the thing they asked for, and hides the
real reason the video could not be fetched.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.media_type import direct_image_extension, failure_means_no_video


class TestDirectImage:
    @pytest.mark.parametrize(
        "path,expected",
        [
            ("/photos/cat.jpg", "jpg"),
            ("/a/b/c.JPEG", "jpeg"),
            ("/x.png", "png"),
            ("/x.webp", "webp"),
            ("/x.gif", "gif"),
            ("/x.bmp", "bmp"),
        ],
    )
    def test_a_real_image_path_is_recognised(self, path, expected):
        assert direct_image_extension(path) == expected

    @pytest.mark.parametrize(
        "path",
        [
            "/watch",
            "/video.mp4",
            "/clip.webm",
            "/song.mp3",
            "/",
            "",
        ],
    )
    def test_anything_else_is_not_an_image(self, path):
        assert direct_image_extension(path) is None

    def test_a_thumbnail_in_the_query_string_does_not_make_it_an_image(self):
        # The bug this replaced searched the whole URL, so every video link
        # carrying a poster parameter came back as a picture.
        from urllib.parse import urlparse

        for url in [
            "https://site.com/watch?v=abc&thumb=cover.jpg",
            "https://site.com/video?poster=https://cdn/x.png",
            "https://site.com/v/123?preview=frame.webp",
        ]:
            assert direct_image_extension(urlparse(url).path) is None, url

    def test_an_extension_shaped_substring_is_not_an_extension(self):
        # "/.gifted/" contains ".gif" and is not a GIF.
        assert direct_image_extension("/.gifted/video") is None
        assert direct_image_extension("/jpgallery/index") is None


class TestScrapeFallback:
    @pytest.mark.parametrize(
        "message",
        [
            "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            "Sign in to confirm you are not a bot",
            "This video is private",
            "Video unavailable. This video is age-restricted",
            "HTTP Error 429: Too Many Requests",
            "This video is not available in your country",
            "members-only content",
            "Requested format is not available",
        ],
    )
    def test_a_video_we_could_not_fetch_is_not_answered_with_pictures(self, message):
        # There is a video here. Scraping the page for images would hand the
        # user a photo and bury the actual reason.
        assert failure_means_no_video(Exception(message)) is False

    @pytest.mark.parametrize(
        "message",
        [
            "Unsupported URL: https://example.com/article",
            "No media found",
            "ERROR: There is no video on this page",
        ],
    )
    def test_a_page_with_no_video_may_fall_back_to_images(self, message):
        assert failure_means_no_video(Exception(message)) is True

    @pytest.mark.parametrize(
        "message",
        [
            "ERROR: There is no video on this page",
            "Unsupported URL: https://blog.example.com/a-message-about-storage",
            "No media found on the homepage",
            "Could not find any playable content",
        ],
    )
    def test_a_word_inside_another_word_is_not_a_match(self, message):
        # The markers were single words at first, so "age" matched "page" and
        # "message", and "bot" matched "about" — a page with no video at all
        # was read as an age-restricted one.
        assert failure_means_no_video(Exception(message)) is True

    @pytest.mark.parametrize(
        "sentence",
        [
            "ERROR: There is no video on this page",
            "Unsupported URL: https://blog.example.com/about-storage",
            "No media found on the homepage",
            "Could not find any playable content",
            "The server returned an empty document",
            "Nothing to download from this address",
        ],
    )
    def test_ordinary_english_does_not_trip_a_marker(self, sentence):
        # The markers are matched as substrings, so any of them that is a short
        # common word will fire on a sentence that has nothing to do with it.
        # This is the guard that keeps them specific.
        assert failure_means_no_video(Exception(sentence)) is True
