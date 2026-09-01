import unittest
from backend.app.downloads import TikTokScraper, DirectMediaScraper, BaseScraper


class TestTikTokScraper(unittest.TestCase):
    def setUp(self):
        self.scraper = TikTokScraper()

    def test_can_handle_tiktok_urls(self):
        valid_urls = [
            "https://www.tiktok.com/@creator/video/7123456789012345678",
            "https://vm.tiktok.com/ZM8abc123/",
            "https://vt.tiktok.com/ZSabc123/",
            "https://m.tiktok.com/v/7123456789012345678.html",
            "https://www.douyin.com/video/7123456789012345678",
        ]
        for url in valid_urls:
            self.assertTrue(self.scraper.can_handle(url), f"TikTok scraper should handle {url}")

    def test_rejects_non_tiktok_urls(self):
        non_tiktok_urls = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.instagram.com/p/C_abc123/",
            "https://twitter.com/user/status/123456",
            "https://example.com/video.mp4",
        ]
        for url in non_tiktok_urls:
            self.assertFalse(self.scraper.can_handle(url), f"TikTok scraper should not handle {url}")


if __name__ == "__main__":
    unittest.main()
