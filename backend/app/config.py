from __future__ import annotations
from pathlib import Path
import os

try:
    from pydantic import BaseModel
except ImportError:
    class BaseModel:
        def __init__(self, **kwargs):
            for k, v in kwargs.items():
                setattr(self, k, v)


def default_public_base_url() -> str:
    if public_base_url := os.getenv("DUCK_PUBLIC_BASE_URL"):
        return public_base_url.rstrip("/")
    if space_host := os.getenv("SPACE_HOST"):
        return f"https://{space_host}".rstrip("/")
    return "http://localhost:8000"


class Settings(BaseModel):
    storage_dir: Path = Path(os.getenv("DUCK_STORAGE_DIR", "./storage/downloads"))
    public_base_url: str = default_public_base_url()
    cookies_file: str | None = os.getenv("DUCK_YTDLP_COOKIES")
    max_download_seconds: int = int(os.getenv("DUCK_MAX_DOWNLOAD_SECONDS", "1800"))
    max_concurrent_downloads: int = int(os.getenv("DUCK_MAX_CONCURRENT_DOWNLOADS", "3"))
    # AI worker (music removal). Runs on the same host and shares storage_dir,
    # so the main API posts an absolute path and the worker processes in place.
    process_worker_url: str = os.getenv("DUCK_PROCESS_WORKER_URL", "http://localhost:8001")
    music_removal_timeout_seconds: int = int(os.getenv("DUCK_MUSIC_REMOVAL_TIMEOUT_SECONDS", "900"))
    # Reading back ad reports. Unset means the read endpoint answers 404 to
    # everyone, including you — complaints written by users are not something
    # to publish by leaving a default in the code.
    ad_reports_token: str = os.getenv("DUCK_AD_REPORTS_TOKEN", "")

    # Where ad reports and their screenshots live.
    #
    # Deliberately not storage_dir. That points at /tmp on the deployed image,
    # which is right for downloads — they are temporary by nature and a wipe
    # costs nothing. Reports are the opposite: their whole value is that they
    # accumulate until the same complaint appears often enough to name an
    # advertiser, and a redeploy resetting the count destroys exactly that.
    #
    # Point this at a mounted volume in production. It falls back to a folder
    # under storage_dir so local runs and tests need no setup.
    reports_dir_override: str = os.getenv("DUCK_REPORTS_DIR", "")

    @property
    def reports_dir(self) -> Path:
        if self.reports_dir_override:
            return Path(self.reports_dir_override)
        return self.storage_dir / "reports"

    @property
    def resolved_cookies_file(self) -> str | None:
        """The operator's own cookies, set by DUCK_YTDLP_COOKIES. Nothing else.

        This used to fall back to `storage_dir/cookies.txt`, a file the app
        wrote to over a public endpoint. On a shared server that made one
        user's harvested session the default credentials for everybody else's
        downloads, and overwrote whatever the previous user had uploaded. User
        cookies now arrive per request and never come to rest here — see
        `app/cookies.py`.
        """
        return self.cookies_file or None


settings = Settings()
settings.storage_dir.mkdir(parents=True, exist_ok=True)
