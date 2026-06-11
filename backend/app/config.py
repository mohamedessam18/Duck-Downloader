from pathlib import Path
from pydantic import BaseModel
import os


class Settings(BaseModel):
    storage_dir: Path = Path(os.getenv("DUCK_STORAGE_DIR", "./storage/downloads"))
    public_base_url: str = os.getenv("DUCK_PUBLIC_BASE_URL", "http://localhost:8000")
    cookies_file: str | None = os.getenv("DUCK_YTDLP_COOKIES")
    max_download_seconds: int = int(os.getenv("DUCK_MAX_DOWNLOAD_SECONDS", "1800"))
    max_concurrent_downloads: int = int(os.getenv("DUCK_MAX_CONCURRENT_DOWNLOADS", "3"))
    pro_license_keys: tuple[str, ...] = tuple(
        key.strip()
        for key in os.getenv("DUCK_PRO_LICENSE_KEYS", "").split(",")
        if key.strip()
    )


settings = Settings()
settings.storage_dir.mkdir(parents=True, exist_ok=True)
