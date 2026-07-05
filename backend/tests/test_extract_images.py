import asyncio
import json
import unittest
from unittest.mock import patch

from backend.app.downloads import DownloadManager
from backend.app.main import public_error


class FakeResponse:
    def __init__(self, body: str, url: str = "https://example.com/", content_type: str = "application/json") -> None:
        self._body = body.encode("utf-8")
        self._url = url
        self.headers = {"Content-Type": content_type}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self) -> bytes:
        return self._body

    def geturl(self) -> str:
        return self._url


class ExtractImagesTest(unittest.TestCase):
    def test_instagram_single_uses_largest_candidate(self) -> None:
        payload = {
            "items": [
                {
                    "media_type": 1,
                    "caption": {"text": "Full size caption"},
                    "image_versions2": {
                        "candidates": [
                            {"url": "https://cdninstagram.com/crop.jpg", "width": 320, "height": 320},
                            {"url": "https://cdninstagram.com/full.jpg", "width": 1440, "height": 1800},
                        ]
                    },
                }
            ]
        }

        def fake_urlopen(req, timeout=10):
            url = req.full_url if hasattr(req, "full_url") else str(req)
            if "i.instagram.com" in url:
                return FakeResponse(json.dumps(payload), url)
            raise OSError("No fallback should be needed")

        with patch("urllib.request.urlopen", fake_urlopen):
            result = asyncio.run(DownloadManager().extract_images("https://www.instagram.com/p/ABC/"))

        self.assertEqual(result["platform"], "Instagram")
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["items"][0]["url"], "https://cdninstagram.com/full.jpg")
        self.assertEqual(result["items"][0]["width"], 1440)
        self.assertEqual(result["items"][0]["height"], 1800)
        self.assertEqual(result["items"][0]["source"], "instagram_api")
        self.assertFalse(result["items"][0]["isPreview"])


    def test_instagram_og_image_only_raises_instead_of_returning_preview(self) -> None:
        html = '''
        <html><head>
          <meta property="og:image" content="https://instagram.com/preview-square.jpg" />
          <title>Preview only</title>
        </head><body></body></html>
        '''

        def fake_urlopen(req, timeout=10):
            url = req.full_url if hasattr(req, "full_url") else str(req)
            if "i.instagram.com" in url or "__a=1" in url:
                raise OSError("No structured media data")
            return FakeResponse(html, url, "text/html; charset=utf-8")

        with patch("urllib.request.urlopen", fake_urlopen):
            with self.assertRaisesRegex(ValueError, "full-size Instagram image"):
                asyncio.run(DownloadManager().extract_images("https://www.instagram.com/p/ABC/"))

    def test_instagram_trusted_square_candidate_is_allowed(self) -> None:
        payload = {
            "items": [
                {
                    "media_type": 1,
                    "image_versions2": {
                        "candidates": [
                            {"url": "https://cdninstagram.com/square.jpg", "width": 1080, "height": 1080}
                        ]
                    },
                }
            ]
        }

        def fake_urlopen(req, timeout=10):
            return FakeResponse(json.dumps(payload))

        with patch("urllib.request.urlopen", fake_urlopen):
            result = asyncio.run(DownloadManager().extract_images("https://www.instagram.com/p/ABC/"))

        self.assertEqual(result["items"][0]["url"], "https://cdninstagram.com/square.jpg")
        self.assertEqual(result["items"][0]["width"], 1080)
        self.assertEqual(result["items"][0]["height"], 1080)
        self.assertFalse(result["items"][0]["isPreview"])
    def test_instagram_carousel_dedupes_and_skips_videos(self) -> None:
        payload = {
            "items": [
                {
                    "media_type": 8,
                    "carousel_media": [
                        {
                            "media_type": 1,
                            "image_versions2": {
                                "candidates": [
                                    {"url": "https://cdninstagram.com/one-small.jpg", "width": 200, "height": 200},
                                    {"url": "https://cdninstagram.com/one-full.jpg", "width": 1200, "height": 1600},
                                ]
                            },
                        },
                        {"media_type": 2},
                        {
                            "media_type": 1,
                            "image_versions2": {
                                "candidates": [
                                    {"url": "https://cdninstagram.com/two-full.jpg", "width": 1200, "height": 1600}
                                ]
                            },
                        },
                        {
                            "media_type": 1,
                            "image_versions2": {
                                "candidates": [
                                    {"url": "https://cdninstagram.com/two-full.jpg", "width": 1200, "height": 1600}
                                ]
                            },
                        },
                    ],
                }
            ]
        }

        def fake_urlopen(req, timeout=10):
            return FakeResponse(json.dumps(payload))

        with patch("urllib.request.urlopen", fake_urlopen):
            result = asyncio.run(DownloadManager().extract_images("https://www.instagram.com/p/ABC/"))

        self.assertEqual([item["url"] for item in result["items"]], [
            "https://cdninstagram.com/one-full.jpg",
            "https://cdninstagram.com/two-full.jpg",
        ])

    def test_instagram_playlist_extract_uses_image_scraper_first(self) -> None:
        manager = DownloadManager()

        async def fake_extract_images(url: str):
            return {
                "title": "Carousel",
                "platform": "Instagram",
                "items": [
                    {"url": "https://cdninstagram.com/one.jpg", "title": "Image 1", "thumbnail": "https://cdninstagram.com/one.jpg"},
                    {"url": "https://cdninstagram.com/two.jpg", "title": "Image 2", "thumbnail": "https://cdninstagram.com/two.jpg"},
                ],
            }

        manager.extract_images = fake_extract_images  # type: ignore[method-assign]
        result = asyncio.run(manager.extract_playlist("https://www.instagram.com/p/ABC/"))

        self.assertEqual([item["url"] for item in result["items"]], [
            "https://cdninstagram.com/one.jpg",
            "https://cdninstagram.com/two.jpg",
        ])
    def test_facebook_public_meta_image_is_returned_without_cookies(self) -> None:
        html = '''
        <html><head>
          <meta property="og:image" content="https://scontent.xx.fbcdn.net/public.jpg" />
          <title>Public Facebook Photo</title>
        </head><body></body></html>
        '''

        def fake_urlopen(req, timeout=10):
            return FakeResponse(html, "https://www.facebook.com/photo.php?fbid=1", "text/html; charset=utf-8")

        with patch("urllib.request.urlopen", fake_urlopen):
            result = asyncio.run(DownloadManager().extract_images("https://www.facebook.com/photo.php?fbid=1"))

        self.assertEqual(result["items"][0]["url"], "https://scontent.xx.fbcdn.net/public.jpg")

    def test_facebook_private_photo_raises_public_only_message(self) -> None:
        html = "<html><title>Log in to Facebook</title><body>Log in to continue</body></html>"

        def fake_urlopen(req, timeout=10):
            return FakeResponse(html, "https://www.facebook.com/photo.php?fbid=1", "text/html; charset=utf-8")

        with patch("urllib.request.urlopen", fake_urlopen):
            with self.assertRaisesRegex(ValueError, "not public or requires login"):
                asyncio.run(DownloadManager().extract_playlist("https://www.facebook.com/photo.php?fbid=1"))



    def test_public_error_preserves_instagram_full_size_message(self) -> None:
        message = "Could not access the full-size Instagram image. This post may require login or cookies."

        self.assertEqual(public_error(ValueError(message)), message)

if __name__ == "__main__":
    unittest.main()
