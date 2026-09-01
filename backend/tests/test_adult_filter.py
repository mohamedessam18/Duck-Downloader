import unittest
from backend.app.security import is_adult_content, validate_not_adult_content, validate_public_url


class TestAdultFilter(unittest.TestCase):
    def test_adult_domains_blocked(self):
        blocked_urls = [
            "https://www.pornhub.com/view_video.php?viewkey=123",
            "https://xvideos.com/video123/test",
            "https://xnxx.com/video-abc",
            "https://sub.xhamster.com/videos/123",
            "https://spankbang.com/abc/video/test",
            "https://rule34.xxx/index.php?page=post",
            "https://nhentai.net/g/123456/",
            "https://redgifs.com/watch/abc",
        ]
        for url in blocked_urls:
            self.assertTrue(is_adult_content(url), f"Should block {url}")
            with self.assertRaises(ValueError):
                validate_public_url(url)
            with self.assertRaises(ValueError):
                validate_not_adult_content(url)

    def test_adult_keywords_in_path_blocked(self):
        blocked_urls = [
            "https://example.com/videos/free-porn-hd.mp4",
            "https://myvideos.net/watch?v=xxx_hot_clip",
            "https://cdn.example.org/hentai/video.mp4",
            "https://testsite.com/camgirls/stream",
        ]
        for url in blocked_urls:
            self.assertTrue(is_adult_content(url), f"Should block {url}")
            with self.assertRaises(ValueError):
                validate_not_adult_content(url)

    def test_safe_urls_allowed(self):
        safe_urls = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.tiktok.com/@user/video/1234567890",
            "https://www.instagram.com/p/C_abc123/",
            "https://www.facebook.com/reel/123456",
            "https://x.com/user/status/123456",
            "https://en.wikipedia.org/wiki/Sussex",
            "https://www.udemy.com/course/python-programming/",
        ]
        for url in safe_urls:
            self.assertFalse(is_adult_content(url), f"Should allow {url}")
            validate_public_url(url)


if __name__ == "__main__":
    unittest.main()
