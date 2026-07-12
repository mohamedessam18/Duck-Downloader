from backend.app.downloads import DownloadManager, DownloadState
from backend.app.models import DownloadType


def test_youtube_download_uses_ytdlp_default_player_clients(tmp_path) -> None:
    """Avoid forcing the less reliable mweb client for normal watch pages."""
    manager = DownloadManager()
    state = DownloadState(
        download_id="test-id",
        url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        download_type=DownloadType.video,
        quality="720p",
        premium_no_watermark=False,
    )

    args = manager._build_ytdlp_args(
        state=state,
        target_dir=tmp_path,
        download_type=DownloadType.video,
        quality="720p",
        prefer_tiktok_no_watermark=False,
    )

    assert "--extractor-args" not in args
