from pathlib import Path
from pydantic import BaseModel
import os


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
    # AI worker (music removal).
    #
    # It needs a GPU and this API does not, so by default the two are separate
    # services that only exchange URLs: the worker fetches the file over HTTP
    # and streams the processed one back. Set
    # DUCK_PROCESS_WORKER_SHARED_VOLUME=1 for a docker-compose setup where they
    # genuinely mount the same disk, and the file is processed in place instead.
    process_worker_url: str = os.getenv("DUCK_PROCESS_WORKER_URL", "http://localhost:8001")
    process_worker_shared_volume: bool = (
        os.getenv("DUCK_PROCESS_WORKER_SHARED_VOLUME", "").strip().lower()
        in {"1", "true", "yes"}
    )
    # Shared secret. Without it, a worker reachable from the internet is a free
    # GPU for whoever finds it.
    process_worker_token: str = os.getenv("DUCK_WORKER_TOKEN", "")
    music_removal_timeout_seconds: int = int(os.getenv("DUCK_MUSIC_REMOVAL_TIMEOUT_SECONDS", "900"))

    @property
    def resolved_cookies_file(self) -> str | None:
        if self.cookies_file:
            return self.cookies_file
        local_path = self.storage_dir / "cookies.txt"
        if local_path.exists():
            return str(local_path.resolve())
        return None


settings = Settings()
settings.storage_dir.mkdir(parents=True, exist_ok=True)
