import asyncio
import re
import shutil
import sys
import urllib.request
import uuid
from pathlib import Path
from typing import Any

from yt_dlp import YoutubeDL

from .config import settings
from .media_type import direct_image_extension, failure_means_no_video
from .models import StatusResponse, DownloadType
from .security import sanitize_filename, ensure_inside, validate_public_url


class DownloadInterrupted(RuntimeError):
    pass


class DownloadState:
    def __init__(
        self,
        download_id: str,
        url: str,
        download_type: DownloadType,
        quality: str | None,
        premium_no_watermark: bool,
        remove_music: bool = False,
    ) -> None:
        self.download_id = download_id
        self.url = url
        self.download_type = download_type
        self.quality = quality
        self.premium_no_watermark = premium_no_watermark
        self.remove_music = remove_music
        self.progress = 0
        self.speed: str | None = None
        self.eta: str | None = None
        self.status = "queued"
        self.file_url: str | None = None
        self.filename: str | None = None
        self.error: str | None = None
        self.pause_requested = False
        self.cancel_requested = False
        self.process: asyncio.subprocess.Process | None = None
        self.subscribers: set[asyncio.Queue[dict[str, Any]]] = set()

    def snapshot(self) -> dict[str, Any]:
        return StatusResponse(
            progress=self.progress,
            speed=self.speed,
            eta=self.eta,
            status=self.status,
            fileUrl=self.file_url,
            filename=self.filename,
            error=self.error,
        ).model_dump(by_alias=True)




class BaseScraper:
    def can_handle(self, url: str) -> bool:
        return False

    async def extract(self, url: str) -> dict[str, Any]:
        raise NotImplementedError()

    async def download(self, state: DownloadState, target_dir: Path, manager: Any) -> None:
        raise NotImplementedError()


class DirectMediaScraper(BaseScraper):
    def can_handle(self, url: str) -> bool:
        from urllib.parse import urlparse
        parsed = urlparse(url)
        path_lower = parsed.path.lower()
        media_extensions = {".mp4", ".mov", ".webm", ".avi", ".mkv", ".mp3", ".wav", ".m4a", ".aac", ".ogg"}
        return any(path_lower.endswith(ext) for ext in media_extensions)

    async def extract(self, url: str) -> dict[str, Any]:
        from urllib.parse import urlparse
        from pathlib import Path
        parsed = urlparse(url)
        path = Path(parsed.path)
        ext = path.suffix.lower().lstrip(".")
        return {
            "title": path.name or "Media File",
            "thumbnail": None,
            "duration": None,
            "platform": parsed.netloc or "Direct Link",
            "qualities": [{"id": "best", "label": "Original File", "ext": ext}],
            "audio_formats": []
        }

    async def download(self, state: DownloadState, target_dir: Path, manager: Any) -> None:
        import urllib.request
        from urllib.parse import urlparse
        from pathlib import Path
        import shutil

        req = urllib.request.Request(
            state.url,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                )
            }
        )

        loop = asyncio.get_running_loop()

        def perform():
            with urllib.request.urlopen(req, timeout=30) as response:
                content_length = response.headers.get("Content-Length")
                total_size = int(content_length) if content_length else 0

                parsed = urlparse(state.url)
                ext = Path(parsed.path).suffix.lower() or ".mp4"
                title = sanitize_filename(Path(parsed.path).stem or "media")
                filename = f"{title}{ext}"
                final_path = ensure_inside(target_dir, target_dir / filename)

                bytes_downloaded = 0
                chunk_size = 1024 * 64

                def update_progress(p):
                    state.progress = p
                    asyncio.run_coroutine_threadsafe(manager._publish(state), loop)

                with open(final_path, "wb") as f:
                    while True:
                        if state.cancel_requested or state.pause_requested:
                            break
                        chunk = response.read(chunk_size)
                        if not chunk:
                            break
                        f.write(chunk)
                        bytes_downloaded += len(chunk)
                        if total_size > 0:
                            p = int((bytes_downloaded / total_size) * 100)
                            if p != state.progress:
                                update_progress(p)

                if not (state.cancel_requested or state.pause_requested):
                    state.filename = filename
                    state.file_url = f"/files/{state.download_id}/{filename}"
                    state.progress = 100
                    update_progress(100)

        await asyncio.to_thread(perform)


def _build_cookie_opener() -> urllib.request.OpenerDirector | None:
    if not settings.resolved_cookies_file:
        return None
    if settings.resolved_cookies_file.startswith("browser:"):
        return None
    try:
        from http.cookiejar import MozillaCookieJar
        cj = MozillaCookieJar(settings.resolved_cookies_file)
        cj.load(ignore_expires=True, ignore_discard=True)
        return urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cj)
        )
    except Exception as exc:
        print(f"DEBUG: Failed to load cookies jar: {exc}", flush=True)
        return None


class DownloadManager:
    def __init__(self) -> None:
        self.states: dict[str, DownloadState] = {}
        self.tasks: dict[str, asyncio.Task[None]] = {}
        self.semaphore = asyncio.Semaphore(settings.max_concurrent_downloads)
        self.scrapers: list[BaseScraper] = [DirectMediaScraper()]

    async def extract(self, url: str) -> dict[str, Any]:
        validate_public_url(url)

        for scraper in self.scrapers:
            if scraper.can_handle(url):
                try:
                    return await scraper.extract(url)
                except Exception:
                    pass

        import urllib.parse
        from pathlib import Path
        parsed = urllib.parse.urlparse(url)
        path = Path(parsed.path)
        host = parsed.netloc.lower()
        if path.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}:
            return {
                "title": path.name or "Image",
                "thumbnail": url,
                "duration": None,
                "platform": parsed.netloc or "Direct Image",
                "qualities": [{"id": "best", "label": "Original Image", "ext": path.suffix.lower().lstrip(".")}],
                "audio_formats": []
            }

        if "instagram.com" in host:
            if not settings.resolved_cookies_file:
                raise ValueError("Could not access the full-size Instagram image. This post may require login or cookies.")

        if "instagram.com" in host or "facebook.com" in host or "fb.watch" in host:
            image_info = await self._extract_image_metadata(url, parsed.netloc)
            if image_info is not None:
                return image_info
            if self._is_facebook_photo_url(url):
                raise ValueError("This Facebook photo is not public or requires login.")

        def run() -> dict[str, Any]:
            with YoutubeDL(self._base_ydl_options(skip_download=True)) as ydl:
                return ydl.extract_info(url, download=False)

        try:
            return await asyncio.to_thread(run)
        except Exception as exc:
            # Fallback 1: the link really is a direct image.
            #
            # This used to search the *whole* URL for ".jpg" and friends, query
            # string included, so any video link carrying a thumbnail parameter
            # came back as an image:
            #
            #   /watch?v=abc&thumb=cover.jpg   ->  "Original Image"
            #
            # It fired whenever yt-dlp failed for any reason, so a video that
            # was merely blocked was handed to the user as a picture. Only the
            # path's own extension counts now.
            if image_ext := direct_image_extension(parsed.path):
                return {
                    "title": "Image",
                    "thumbnail": url,
                    "duration": None,
                    "platform": parsed.netloc or "Direct Image",
                    "qualities": [{"id": "best", "label": "Original Image", "ext": image_ext}],
                    "audio_formats": []
                }

            # Fallback 2: scrape the page for images.
            #
            # Only when the failure means "there is no video here". A link that
            # yt-dlp recognises and then cannot fetch — private, age-gated,
            # blocked, rate-limited — is a video, and answering with a picture
            # off the page hides the real reason from the user.
            if failure_means_no_video(exc) and not any(domain in host for domain in ["youtube.com", "youtu.be", "tiktok.com", "instagram.com", "facebook.com", "fb.watch"]):
                try:
                    images_info = await self.extract_images(url)
                    if images_info and images_info.get("items"):
                        first_img = images_info["items"][0]
                        title = images_info.get("title") or "Scraped Image"
                        return {
                            "title": title,
                            "thumbnail": first_img["url"],
                            "duration": None,
                            "platform": images_info.get("platform") or parsed.netloc or "Webpage",
                            "qualities": [{"id": "best", "label": "Original Image", "ext": "jpg"}],
                            "audio_formats": []
                        }
                except Exception:
                    pass

            raise exc

    def _is_facebook_photo_url(self, url: str) -> bool:
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(url)
        host = parsed.netloc.lower()
        if "facebook.com" not in host and "fb.watch" not in host:
            return False
        path = parsed.path.lower()
        query = parse_qs(parsed.query)
        return (
            "photo" in path
            or "photos" in path
            or "photo.php" in path
            or "story_fbid" in query
            or "fbid" in query
        )

    async def _extract_image_metadata(self, url: str, fallback_platform: str) -> dict[str, Any] | None:
        images_info = await self.extract_images(url)
        items = images_info.get("items") or []
        if not items:
            return None
        first_img = items[0]
        title = images_info.get("title") or first_img.get("title") or "Image"
        return {
            "title": title,
            "thumbnail": first_img["url"],
            "duration": None,
            "platform": images_info.get("platform") or fallback_platform or "Webpage",
            "qualities": [{"id": "best", "label": "Original Image", "ext": "jpg"}],
            "audio_formats": [],
        }

    def _base_ydl_options(self, *, skip_download: bool = False) -> dict[str, Any]:
        has_impersonate = False
        try:
            import curl_cffi
            has_impersonate = True
        except ImportError:
            pass

        opts: dict[str, Any] = {
            "quiet": True,
            "skip_download": skip_download,
            "noplaylist": True,
            "cachedir": False,
            "retries": 3,
            "fragment_retries": 3,
            "socket_timeout": 30,
            "http_headers": {
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                ),
                "Accept-Language": "en-US,en;q=0.9",
            },
            # YouTube hands out its stream URLs behind a JavaScript challenge,
            # and yt-dlp needs a JS runtime to solve it. It enables only `deno`
            # by default and this image does not ship one, so every YouTube
            # download failed at the last step with `HTTP Error 403: Forbidden`
            # after appearing to start — extraction succeeded and only the media
            # fetch was refused, which is why it read as a network problem
            # rather than a missing dependency.
            #
            # Node is already in the image for the PO token provider. Pointed at
            # by path rather than trusting PATH, because it is copied in from
            # another build stage rather than installed by the package manager.
            "js_runtimes": {"node": {"path": "/usr/local/bin/node"}},
            # Do not force a particular YouTube player client here. yt-dlp's
            # current defaults choose the most compatible clients for each
            # video, while the local bgutil provider supplies PO tokens when a
            # selected client needs one. Forcing mweb worked for many Shorts
            # but made regular watch pages more likely to hit bot checks.
            "extractor_args": {
                "youtubepot-bgutilhttp": {
                    "base_url": "http://localhost:4416"
                }
            }
        }
        if has_impersonate:
            try:
                from yt_dlp.networking.impersonate import ImpersonateTarget
                opts["impersonate"] = ImpersonateTarget.from_str("chrome")
            except Exception:
                pass

        if settings.resolved_cookies_file:
            if settings.resolved_cookies_file.startswith("browser:"):
                browser_name = settings.resolved_cookies_file.split("browser:", 1)[1].strip()
                opts["cookiesfrombrowser"] = (browser_name,)
            else:
                opts["cookiefile"] = settings.resolved_cookies_file
        return opts

    async def start(
        self,
        url: str,
        download_type: DownloadType,
        quality: str | None,
        premium_no_watermark: bool = False,
        remove_music: bool = False,
    ) -> str:
        validate_public_url(url)
        download_id = uuid.uuid4().hex
        state = DownloadState(download_id, url, download_type, quality, premium_no_watermark, remove_music)
        self.states[download_id] = state
        self._schedule(download_id)
        return download_id

    def _schedule(self, download_id: str) -> None:
        state = self.states[download_id]
        self.tasks[download_id] = asyncio.create_task(
            self._download(
                download_id,
                state.url,
                state.download_type,
                state.quality,
                state.premium_no_watermark,
                state.remove_music,
            )
        )

    async def pause(self, download_id: str) -> DownloadState | None:
        state = self.states.get(download_id)
        if state is None:
            return None
        if state.status in {"completed", "failed", "cancelled"}:
            return state
        state.pause_requested = True
        state.status = "paused"
        await self._stop_process(state)
        await self._publish(state)
        return state

    async def resume(self, download_id: str) -> DownloadState | None:
        state = self.states.get(download_id)
        if state is None:
            return None
        if state.status != "paused":
            return state
        state.pause_requested = False
        state.cancel_requested = False
        state.error = None
        state.status = "queued"
        await self._publish(state)
        self._schedule(download_id)
        return state

    async def cancel(self, download_id: str) -> DownloadState | None:
        state = self.states.get(download_id)
        if state is None:
            return None
        if state.status in {"completed", "failed", "cancelled"}:
            return state
        state.cancel_requested = True
        state.status = "cancelled"
        await self._stop_process(state)
        self._cleanup_download_dir(download_id)
        await self._publish(state)
        return state

    async def _publish(self, state: DownloadState) -> None:
        payload = state.snapshot()
        for queue in list(state.subscribers):
            await queue.put(payload)

    async def _stop_process(self, state: DownloadState) -> None:
        process = state.process
        if process is None or process.returncode is not None:
            return
        process.terminate()
        try:
            await asyncio.wait_for(process.wait(), timeout=3)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()

    def _cleanup_download_dir(self, download_id: str) -> None:
        target_dir = ensure_inside(settings.storage_dir, settings.storage_dir / download_id)
        if target_dir.exists():
            shutil.rmtree(target_dir, ignore_errors=True)

    async def _download(
        self,
        download_id: str,
        url: str,
        download_type: DownloadType,
        quality: str | None,
        premium_no_watermark: bool,
        remove_music: bool,
    ) -> None:
        state = self.states[download_id]
        try:
            async with self.semaphore:
                if state.cancel_requested:
                    state.status = "cancelled"
                    await self._publish(state)
                    return
                if state.pause_requested:
                    state.status = "paused"
                    await self._publish(state)
                    return
                state.status = "downloading"
                await self._publish(state)

                target_dir = ensure_inside(settings.storage_dir, settings.storage_dir / download_id)
                target_dir.mkdir(parents=True, exist_ok=True)

                try:
                    matched_scraper = None
                    for scraper in self.scrapers:
                        if scraper.can_handle(url):
                            matched_scraper = scraper
                            break

                    if matched_scraper:
                        await asyncio.wait_for(
                            matched_scraper.download(state, target_dir, self),
                            timeout=settings.max_download_seconds,
                        )
                        if not (state.cancel_requested or state.pause_requested):
                            if remove_music:
                                await self._remove_music_via_worker(state, target_dir)
                            state.status = "completed"
                    elif download_type == DownloadType.image:
                        await asyncio.wait_for(
                            self._download_image_directly(state, target_dir),
                            timeout=60,
                        )
                        state.status = "completed"
                    else:
                        await asyncio.wait_for(
                            self._run_download_process(
                                state=state,
                                target_dir=target_dir,
                                download_type=download_type,
                                quality=quality,
                                premium_no_watermark=premium_no_watermark,
                            ),
                            timeout=settings.max_download_seconds,
                        )
                        if state.cancel_requested:
                            state.status = "cancelled"
                        elif state.pause_requested:
                            state.status = "paused"
                        else:
                            if remove_music:
                                await self._remove_music_via_worker(state, target_dir)
                            state.progress = 100
                            state.status = "completed"
                except DownloadInterrupted:
                    if state.cancel_requested:
                        state.status = "cancelled"
                        state.error = None
                    elif state.pause_requested:
                        state.status = "paused"
                        state.error = None
                    else:
                        state.status = "failed"
                        state.error = "Download stopped."
                except asyncio.TimeoutError:
                    await self._stop_process(state)
                    state.status = "failed"
                    state.error = "Download timed out."
                except Exception as exc:
                    if state.cancel_requested:
                        state.status = "cancelled"
                        state.error = None
                    elif state.pause_requested:
                        state.status = "paused"
                        state.error = None
                    else:
                        state.status = "failed"
                        state.error = str(exc)
                        import traceback
                        print(f"DOWNLOAD EXCEPTION: {exc}", flush=True)
                        traceback.print_exc()
                await self._publish(state)
        finally:
            state.process = None
            if state.status == "cancelled":
                self._cleanup_download_dir(download_id)
            if self.tasks.get(download_id) is asyncio.current_task():
                self.tasks.pop(download_id, None)

    async def _remove_music_via_worker(self, state: DownloadState, target_dir: Path) -> None:
        """Hands the finished file to the GPU worker and takes back the result.

        The worker used to be given a filesystem path, which quietly required
        it to be the same machine as this API — so putting Demucs on a graphics
        card meant moving the whole API onto a GPU host and renting a card to
        serve JSON. It now gets a URL and streams the processed file back, and
        the two only need to be able to reach each other.

        ``DUCK_PROCESS_WORKER_SHARED_VOLUME`` switches back to the path mode for
        a docker-compose setup where they really do share a disk.
        """

        if not state.filename:
            return
        state.status = "processing"
        state.progress = 99
        await self._publish(state)

        target = Path(target_dir / state.filename)
        output_format = "mp3" if state.download_type == DownloadType.audio else "mp4"

        if settings.process_worker_shared_volume:
            await asyncio.to_thread(
                self._call_worker_in_place, str(target.resolve()), output_format
            )
            return

        await asyncio.to_thread(
            self._call_worker_streaming,
            f"{settings.public_base_url}/files/{state.download_id}/{state.filename}",
            target,
            output_format,
        )

    @staticmethod
    def _worker_headers() -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if settings.process_worker_token:
            headers["X-Duck-Worker-Token"] = settings.process_worker_token
        return headers

    @staticmethod
    def _worker_error(exc: Exception) -> RuntimeError:
        import urllib.error
        import json

        if isinstance(exc, urllib.error.HTTPError):
            body = exc.read().decode("utf-8", errors="replace")
            try:
                detail = json.loads(body).get("detail", "Music removal failed.")
            except Exception:
                detail = body or "Music removal failed."
            return RuntimeError(detail)
        return RuntimeError(f"Could not reach the music removal worker: {exc}")

    def _call_worker_in_place(self, input_path: str, output_format: str) -> None:
        """Same-host mode: the worker overwrites the file on the shared volume."""
        import urllib.request
        import json

        request = urllib.request.Request(
            f"{settings.process_worker_url}/process",
            data=json.dumps(
                {"input_path": input_path, "output_format": output_format}
            ).encode("utf-8"),
            headers=self._worker_headers(),
            method="POST",
        )
        try:
            with urllib.request.urlopen(
                request, timeout=settings.music_removal_timeout_seconds
            ) as response:
                json.loads(response.read().decode("utf-8"))
        except Exception as exc:
            raise self._worker_error(exc) from exc

    def _call_worker_streaming(
        self, input_url: str, target: Path, output_format: str
    ) -> None:
        """Remote mode: send a URL, receive the processed file as the body.

        Written to a sibling temp file and moved into place, so a transfer that
        dies halfway never leaves a truncated file where the finished download
        used to be — the client may already be downloading it.
        """
        import urllib.request
        import json
        import shutil
        import tempfile

        request = urllib.request.Request(
            f"{settings.process_worker_url}/process/stream",
            data=json.dumps(
                {"input_url": input_url, "output_format": output_format}
            ).encode("utf-8"),
            headers=self._worker_headers(),
            method="POST",
        )

        temp_dir = Path(tempfile.mkdtemp(prefix="duck-nomusic-", dir=str(target.parent)))
        temp_output = temp_dir / target.name
        try:
            with urllib.request.urlopen(
                request, timeout=settings.music_removal_timeout_seconds
            ) as response:
                with temp_output.open("wb") as out:
                    shutil.copyfileobj(response, out, 1024 * 1024)
            if temp_output.stat().st_size == 0:
                raise RuntimeError("The worker returned an empty file.")
            shutil.move(str(temp_output), str(target))
        except Exception as exc:
            raise self._worker_error(exc) from exc
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    async def _download_image_directly(self, state: DownloadState, target_dir: Path) -> None:
        import urllib.request
        from urllib.parse import urlparse
        import mimetypes
        import shutil

        opener = _build_cookie_opener()
        _urlopen = opener.open if opener else urllib.request.urlopen
        loop = asyncio.get_running_loop()

        url_to_download = state.url
        parsed_url = urlparse(state.url)
        path_ext = Path(parsed_url.path).suffix.lower()

        # For social media URLs, use extract_images to get actual CDN URLs
        images_to_download: list[dict[str, str]] = []
        _url_host = parsed_url.netloc.lower()
        _is_cdn = any(cdn in _url_host for cdn in ["cdninstagram", "fbcdn", "scontent", "pbs.twimg", "twimg"])
        if path_ext not in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"} and not _is_cdn:
            try:
                images_info = await self.extract_images(state.url)
                if images_info and images_info.get("items"):
                    images_to_download = [
                        {"url": item["url"], "title": item.get("title", f"Image {i+1}")}
                        for i, item in enumerate(images_info["items"])
                    ]
            except Exception:
                pass

        # Fallback: download the original URL directly
        if not images_to_download:
            if self._is_facebook_photo_url(state.url):
                raise ValueError("This Facebook photo is not public or requires login.")
            images_to_download = [{"url": url_to_download, "title": "image"}]


        def build_headers(download_url: str) -> dict[str, str]:
            h: dict[str, str] = {
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                ),
                "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            }
            dl_lower = download_url.lower()
            if "instagram.com" in dl_lower or "cdninstagram" in dl_lower or "fbcdn" in dl_lower:
                h["Referer"] = "https://www.instagram.com/"
            elif "facebook.com" in dl_lower:
                h["Referer"] = "https://www.facebook.com/"
            elif "tiktok.com" in dl_lower or "tiktokcdn" in dl_lower or "byteoversea" in dl_lower or "tiktokv" in dl_lower:
                h["Referer"] = "https://www.tiktok.com/"
            return h

        def download_single(img_url: str, img_title: str, index: int, total: int) -> tuple[str, str]:
            """Download one image; returns (filename, file_url)."""
            req = urllib.request.Request(img_url, headers=build_headers(img_url))
            with _urlopen(req, timeout=30) as response:
                content_type = response.headers.get("Content-Type", "")
                ct_clean = content_type.split(";")[0].strip().lower()
                if ct_clean in {"text/html", "application/json", "text/plain"}:
                    raise RuntimeError(
                        f"URL did not return an image (Content-Type: '{ct_clean}')."
                    )
                ext = mimetypes.guess_extension(ct_clean) or ""
                if not ext:
                    p_ext = Path(urlparse(img_url).path).suffix.lower()
                    ext = p_ext if p_ext in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"} else ".jpg"
                if not ext.startswith("."):
                    ext = f".{ext}"
                ext = ext.lower()
                if ext in {".jpe", ".jpeg"}:
                    ext = ".jpg"

                stem = Path(urlparse(img_url).path).stem
                if not stem or len(stem) > 50:
                    stem = sanitize_filename(img_title) or "image"
                if total > 1:
                    filename = f"{sanitize_filename(stem)}_{index+1:02d}{ext}"
                else:
                    filename = f"{sanitize_filename(stem)}{ext}"
                final_path = ensure_inside(target_dir, target_dir / filename)

                content_length = response.headers.get("Content-Length")
                total_size = int(content_length) if content_length else 0
                bytes_downloaded = 0
                chunk_size = 1024 * 64

                def update_progress(p: int) -> None:
                    base = int(index * 100 / total)
                    scaled = min(99, base + int(p / total))
                    state.progress = scaled
                    asyncio.run_coroutine_threadsafe(self._publish(state), loop)

                with open(final_path, "wb") as f:
                    while True:
                        if state.cancel_requested or state.pause_requested:
                            break
                        chunk = response.read(chunk_size)
                        if not chunk:
                            break
                        f.write(chunk)
                        bytes_downloaded += len(chunk)
                        if total_size > 0:
                            pct = int((bytes_downloaded / total_size) * 100)
                            if pct != state.progress:
                                update_progress(pct)

                return filename, f"/files/{state.download_id}/{filename}"

        total = len(images_to_download)
        last_filename = ""
        last_file_url = ""

        for idx, img in enumerate(images_to_download):
            if state.cancel_requested or state.pause_requested:
                break
            try:
                fname, furl = await asyncio.to_thread(
                    download_single, img["url"], img["title"], idx, total
                )
                last_filename = fname
                last_file_url = furl
            except Exception as exc:
                if total == 1:
                    raise
                state.error = f"Skipped image {idx+1}: {exc}"
                await self._publish(state)

        if not (state.cancel_requested or state.pause_requested) and last_filename:
            state.filename = last_filename
            state.file_url = last_file_url
            state.progress = 100
            asyncio.run_coroutine_threadsafe(self._publish(state), loop)

    async def _run_download_process(
        self,
        *,
        state: DownloadState,
        target_dir: Path,
        download_type: DownloadType,
        quality: str | None,
        premium_no_watermark: bool,
    ) -> None:
        is_tiktok = "tiktok" in state.url.lower()
        attempts = [premium_no_watermark and download_type == DownloadType.video and is_tiktok, False]
        last_error: Exception | None = None

        for prefer_tiktok_no_watermark in dict.fromkeys(attempts):
            try:
                await self._run_ytdlp_once(
                    state=state,
                    target_dir=target_dir,
                    download_type=download_type,
                    quality=quality,
                    prefer_tiktok_no_watermark=prefer_tiktok_no_watermark,
                )
                produced = self._find_produced_file(target_dir, download_type)
                title = sanitize_filename(produced.stem)
                if download_type == DownloadType.image or produced.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}:
                    ext = produced.suffix.lower().lstrip(".")
                else:
                    ext = "mp3" if download_type == DownloadType.audio else "mp4"
                final_path = ensure_inside(target_dir, target_dir / f"{title}.{ext}")
                if produced.resolve() != final_path.resolve():
                    produced.replace(final_path)
                state.filename = final_path.name
                state.file_url = f"/files/{state.download_id}/{final_path.name}"
                return
            except DownloadInterrupted:
                raise
            except Exception as exc:
                last_error = exc
                if not prefer_tiktok_no_watermark:
                    err_msg = str(exc).lower()
                    url_lower = state.url.lower()
                    if "no video" in err_msg or "there is no video" in err_msg or any(domain in url_lower for domain in ["instagram.com", "twitter.com", "x.com", "pinterest.com", "tiktok.com", "tiktokv.com"]):
                        try:
                            await self._download_image_directly(state, target_dir)
                            return
                        except Exception as e:
                            raise RuntimeError(f"Direct image download failed: {e}") from e
                    raise

        if last_error is not None:
            raise last_error

    async def _run_ytdlp_once(
        self,
        *,
        state: DownloadState,
        target_dir: Path,
        download_type: DownloadType,
        quality: str | None,
        prefer_tiktok_no_watermark: bool,
    ) -> None:
        args = self._build_ytdlp_args(
            state=state,
            target_dir=target_dir,
            download_type=download_type,
            quality=quality,
            prefer_tiktok_no_watermark=prefer_tiktok_no_watermark,
        )
        process = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        state.process = process
        output: list[str] = []
        assert process.stdout is not None

        while True:
            line_bytes = await process.stdout.readline()
            if not line_bytes:
                break
            line = line_bytes.decode("utf-8", errors="replace").strip()
            if line:
                output.append(line)
                await self._handle_ytdlp_line(state, line)

        return_code = await process.wait()
        state.process = None
        if state.cancel_requested or state.pause_requested:
            raise DownloadInterrupted()
        if return_code != 0:
            err_lines = [l for l in output if not (l.startswith("[download]") and "%" in l)]
            details = "\n".join(err_lines[-6:]).strip()
            error_msg = details or f"yt-dlp failed with exit code {return_code}."
            # Provide friendly messages for common auth/restriction errors
            error_lower = error_msg.lower()
            if "registered users" in error_lower or ("only available" in error_lower and "facebook" in state.url.lower()):
                raise RuntimeError(
                    "This Facebook post requires a logged-in account to access. "
                    "Use the Cookie Settings (🍪) button in the app to paste your Facebook cookies.txt and enable authenticated downloads."
                )
            if "registered users" in error_lower or "cookies" in error_lower:
                raise RuntimeError(
                    "This content requires authentication. "
                    "Use the Cookie Settings (🍪) button in the app to paste your cookies.txt."
                )
            raise RuntimeError(error_msg)

    def _build_ytdlp_args(
        self,
        *,
        state: DownloadState,
        target_dir: Path,
        download_type: DownloadType,
        quality: str | None,
        prefer_tiktok_no_watermark: bool,
    ) -> list[str]:
        format_selector = self._format_selector(download_type, quality)
        
        has_impersonate = False
        try:
            import curl_cffi
            has_impersonate = True
        except ImportError:
            pass

        args = [
            sys.executable,
            "-m",
            "yt_dlp",
            "--newline",
            "--no-playlist",
            "--no-cache-dir",
            "--retries",
            "3",
            "--fragment-retries",
            "3",
            "--socket-timeout",
            "30",
        ]
        if has_impersonate:
            args.extend(["--impersonate", "chrome"])

        # YouTube serves its stream URLs behind a JavaScript challenge, and
        # yt-dlp needs a runtime to solve it. It enables only `deno` by
        # default and this image ships none, so the *download* failed with
        # `HTTP Error 403: Forbidden` while extraction — which runs through the
        # Python API in another method — succeeded. The user saw the real title
        # and the real qualities, picked one, and got nothing.
        #
        # Node is already here for the PO token provider. Appended rather than
        # replacing the default, so a future image that does ship deno keeps
        # using it: yt-dlp picks the highest-priority runtime that is both
        # enabled and actually present.
        args.extend(["--js-runtimes", "node:/usr/local/bin/node"])

        args.extend([
            "--continue",
            "--restrict-filenames",
            "--windows-filenames",
            "--add-header",
            "Accept-Language:en-US,en;q=0.9",
            "-f",
            format_selector,
            "-o",
            str(target_dir / "%(title).140s.%(ext)s"),
        ])
        if settings.resolved_cookies_file:
            if settings.resolved_cookies_file.startswith("browser:"):
                browser_name = settings.resolved_cookies_file.split("browser:", 1)[1].strip()
                args.extend(["--cookies-from-browser", browser_name])
            else:
                args.extend(["--cookies", settings.resolved_cookies_file])
        if download_type == DownloadType.video:
            args.extend(["--merge-output-format", "mp4"])
        if prefer_tiktok_no_watermark:
            args.extend([
                "--extractor-args",
                "tiktok:api_hostname=api16-normal-c-useast1a.tiktokv.com",
            ])
        if download_type == DownloadType.audio:
            args.extend(["-x", "--audio-format", "mp3", "--audio-quality", "192K"])
        args.append(state.url)
        return args

    def _format_selector(self, download_type: DownloadType, quality: str | None) -> str:
        if download_type == DownloadType.audio:
            return "bestaudio/best"

        has_ffmpeg = shutil.which("ffmpeg") is not None
        if quality:
            numeric = "".join(ch for ch in quality if ch.isdigit())
            if numeric:
                if has_ffmpeg:
                    return (
                        f"bestvideo[height<={numeric}]+bestaudio/"
                        f"best[height<={numeric}]/"
                        f"best"
                    )
                else:
                    return (
                        f"best[height<={numeric}][ext=mp4]/"
                        f"best[height<={numeric}]/"
                        f"best"
                    )

        if has_ffmpeg:
            return "bestvideo+bestaudio/best"
        return "best[ext=mp4]/best"


    async def _handle_ytdlp_line(self, state: DownloadState, line: str) -> None:
        if state.cancel_requested or state.pause_requested:
            await self._stop_process(state)
            return
        if line.startswith("[download]") and "%" in line:
            percent_match = re.search(r"(\d+(?:\.\d+)?)%", line)
            speed_match = re.search(r"at\s+([^\s]+)", line)
            eta_match = re.search(r"ETA\s+([^\s]+)", line)
            if percent_match:
                state.progress = max(0, min(100, int(float(percent_match.group(1)))))
            if speed_match:
                state.speed = speed_match.group(1)
            if eta_match:
                state.eta = eta_match.group(1)
            state.status = "downloading"
            await self._publish(state)
        elif line.startswith("[Merger]") or line.startswith("[ExtractAudio]"):
            state.progress = min(state.progress, 99)
            state.speed = None
            state.eta = None
            state.status = "processing"
            await self._publish(state)

    def _find_produced_file(self, target_dir: Path, download_type: DownloadType) -> Path:
        suffix = ".mp3" if download_type == DownloadType.audio else ".mp4"
        candidates = [
            item
            for item in target_dir.glob("*")
            if item.is_file() and item.suffix.lower() == suffix and not item.name.endswith(".part")
        ]
        if not candidates:
            candidates = [
                item
                for item in target_dir.glob("*")
                if item.is_file() and not item.name.endswith((".part", ".ytdl"))
            ]
        if not candidates:
            raise RuntimeError("yt-dlp completed but no file was produced.")
        return max(candidates, key=lambda item: item.stat().st_mtime)

    def status(self, download_id: str) -> DownloadState | None:
        return self.states.get(download_id)

    async def extract_playlist(self, url: str) -> dict[str, Any]:
        validate_public_url(url)
        from urllib.parse import urlparse
        parsed = urlparse(url)
        host = parsed.netloc.lower()
        path = parsed.path.lower()
        if "instagram.com" in host:
            if not settings.resolved_cookies_file:
                raise ValueError("Could not access the full-size Instagram image. This post may require login or cookies.")

        if "instagram.com" in host and any(part in path for part in ("/p/", "/reel/", "/reels/", "/tv/")):
            images_info = await self.extract_images(url)
            if images_info.get("items"):
                return images_info
        if self._is_facebook_photo_url(url):
            images_info = await self.extract_images(url)
            if not images_info.get("items"):
                raise ValueError("This Facebook photo is not public or requires login.")
            return images_info

        def run() -> dict[str, Any]:
            opts = self._base_ydl_options(skip_download=True)
            opts["noplaylist"] = False
            opts["extract_flat"] = True
            with YoutubeDL(opts) as ydl:
                res = ydl.extract_info(url, download=False)
                entries = res.get("entries") or []
                parsed_items = []
                for entry in entries:
                    if not entry:
                        continue
                    entry_url = entry.get("url") or entry.get("webpage_url")
                    if not entry_url and entry.get("id"):
                        extractor = entry.get("ie_key") or res.get("extractor_key") or ""
                        if "youtube" in extractor.lower() or "youtube" in url:
                            entry_url = f"https://www.youtube.com/watch?v={entry.get('id')}"
                        else:
                            entry_url = entry.get("id")

                    if entry_url:
                        parsed_items.append({
                            "url": entry_url,
                            "title": entry.get("title") or "Untitled Video",
                            "thumbnail": entry.get("thumbnail"),
                        })
                return {
                    "title": res.get("title") or "Untitled Playlist",
                    "platform": res.get("extractor_key") or res.get("extractor") or "Public playlist",
                    "items": parsed_items,
                }

        return await asyncio.to_thread(run)

    async def extract_images(self, url: str) -> dict[str, Any]:
        validate_public_url(url)

        opener = _build_cookie_opener()

        def run() -> dict[str, Any]:
            import urllib.request
            from urllib.parse import urljoin, urlparse
            from html.parser import HTMLParser
            import re
            import json
            parsed_origin = urlparse(url)
            is_facebook_url = "facebook.com" in parsed_origin.netloc.lower() or "fb.watch" in parsed_origin.netloc.lower()
            _urlopen = urllib.request.urlopen if is_facebook_url else (opener.open if opener else urllib.request.urlopen)

            def unique_image_items(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
                seen: set[str] = set()
                unique: list[dict[str, Any]] = []
                for item in items:
                    item_url = item.get("url")
                    if not item_url or item_url in seen:
                        continue
                    seen.add(item_url)
                    unique.append(item)
                return unique

            if "instagram.com" in parsed_origin.netloc.lower():
                shortcode_match = re.search(r"/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)", parsed_origin.path)
                if shortcode_match:
                    shortcode = shortcode_match.group(1)
                    alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
                    media_id = 0
                    for char in shortcode:
                        media_id = (media_id * 64) + alphabet.index(char)

                    images = []
                    title_text = "Instagram Post"

                    def find_shortcode_media(data: Any) -> Any:
                        if isinstance(data, dict):
                            if "shortcode_media" in data:
                                return data["shortcode_media"]
                            for v in data.values():
                                res = find_shortcode_media(v)
                                if res:
                                    return res
                        elif isinstance(data, list):
                            for item in data:
                                res = find_shortcode_media(item)
                                if res:
                                    return res
                        return None

                    def find_keys(data: Any, target_key: str) -> list[Any]:
                        results = []
                        if isinstance(data, dict):
                            for k, v in data.items():
                                if k == target_key:
                                    results.append(v)
                                else:
                                    results.extend(find_keys(v, target_key))
                        elif isinstance(data, list):
                            for item in data:
                                results.extend(find_keys(item, target_key))
                        return results

                    def make_image_item(
                        image_url: str,
                        title: str,
                        width: int | None,
                        height: int | None,
                        source: str,
                        *,
                        is_preview: bool = False,
                    ) -> dict[str, Any]:
                        return {
                            "url": image_url,
                            "title": title,
                            "thumbnail": image_url,
                            "width": width,
                            "height": height,
                            "source": source,
                            "isPreview": is_preview,
                            "isVideo": False,
                        }

                    def best_candidate(candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
                        """Pick the candidate with the largest known area."""
                        usable = [c for c in candidates if c.get("url")]
                        if not usable:
                            return None
                        return max(
                            usable,
                            key=lambda c: (c.get("width") or 0) * (c.get("height") or 0),
                        )

                    def display_resource_item(resource: dict[str, Any], title: str, source: str) -> dict[str, Any] | None:
                        image_url = resource.get("src")
                        if not image_url:
                            return None
                        return make_image_item(
                            image_url,
                            title,
                            resource.get("config_width"),
                            resource.get("config_height"),
                            source,
                        )

                    def candidate_item(candidate: dict[str, Any], title: str, source: str) -> dict[str, Any] | None:
                        image_url = candidate.get("url")
                        if not image_url:
                            return None
                        return make_image_item(
                            image_url,
                            title,
                            candidate.get("width"),
                            candidate.get("height"),
                            source,
                        )

                    def parse_from_media_data(media_data: dict[str, Any]) -> list[dict[str, Any]]:
                        parsed_imgs = []
                        carousel_edges = media_data.get("edge_sidecar_to_children", {}).get("edges", [])
                        if carousel_edges:
                            for idx, edge in enumerate(carousel_edges):
                                node = edge.get("node", {})
                                if node.get("is_video"):
                                    video_url = node.get("video_url")
                                    if video_url:
                                        parsed_imgs.append({
                                            "url": video_url,
                                            "title": f"Video {idx + 1}",
                                            "thumbnail": node.get("display_url"),
                                            "width": node.get("dimensions", {}).get("width"),
                                            "height": node.get("dimensions", {}).get("height"),
                                            "source": "instagram_web_script",
                                            "isVideo": True
                                        })
                                    continue
                                # Prefer display_resources (highest res) over display_url
                                resources = node.get("display_resources") or []
                                if resources:
                                    best_res = max(resources, key=lambda r: (r.get("config_width") or 0) * (r.get("config_height") or 0))
                                    item = display_resource_item(best_res, f"Image {idx + 1}", "instagram_web_script")
                                    if item:
                                        parsed_imgs.append(item)
                        else:
                            if media_data.get("is_video"):
                                video_url = media_data.get("video_url")
                                if video_url:
                                    parsed_imgs.append({
                                        "url": video_url,
                                        "title": "Video 1",
                                        "thumbnail": media_data.get("display_url"),
                                        "width": media_data.get("dimensions", {}).get("width"),
                                        "height": media_data.get("dimensions", {}).get("height"),
                                        "source": "instagram_web_script",
                                        "isVideo": True
                                    })
                                return parsed_imgs
                            resources = media_data.get("display_resources") or []
                            if resources:
                                best_res = max(resources, key=lambda r: (r.get("config_width") or 0) * (r.get("config_height") or 0))
                                item = display_resource_item(best_res, "Image 1", "instagram_web_script")
                                if item:
                                    parsed_imgs.append(item)
                        return parsed_imgs

                    # Attempt 1: Call i.instagram.com media info API
                    headers_api = {
                        "User-Agent": "Instagram 219.0.0.12.117 Android (29/10; 480dpi; 1080x1920; samsung; SM-G960F; starqlte; exynos9810; en_US; 329061321)",
                        "Accept": "application/json",
                        "X-IG-App-ID": "936619743392459",
                    }
                    req_api = urllib.request.Request(
                        f"https://i.instagram.com/api/v1/media/{media_id}/info/",
                        headers=headers_api
                    )
                    try:
                        with _urlopen(req_api, timeout=10) as response:
                            res_data = json.loads(response.read().decode("utf-8"))
                            items = res_data.get("items", [])
                            if items:
                                post = items[0]
                                carousel = post.get("carousel_media", [])
                                if carousel:
                                    for idx, item in enumerate(carousel):
                                        if item.get("media_type") == 2:  # 2 = video
                                            video_versions = item.get("video_versions", [])
                                            if video_versions:
                                                best_video = max(video_versions, key=lambda v: (v.get("width") or 0) * (v.get("height") or 0))
                                                video_url = best_video.get("url")
                                                if video_url:
                                                    images.append({
                                                        "url": video_url,
                                                        "title": f"Video {idx + 1}",
                                                        "thumbnail": item.get("image_versions2", {}).get("candidates", [{}])[0].get("url"),
                                                        "width": best_video.get("width"),
                                                        "height": best_video.get("height"),
                                                        "source": "instagram_api",
                                                        "isVideo": True
                                                    })
                                            continue
                                        img_versions = item.get("image_versions2", {})
                                        candidates = img_versions.get("candidates", [])
                                        best = best_candidate(candidates)
                                        item_data = candidate_item(best, f"Image {idx + 1}", "instagram_api") if best else None
                                        if item_data:
                                            images.append(item_data)
                                else:
                                    if post.get("media_type") == 2:  # video
                                        video_versions = post.get("video_versions", [])
                                        if video_versions:
                                            best_video = max(video_versions, key=lambda v: (v.get("width") or 0) * (v.get("height") or 0))
                                            video_url = best_video.get("url")
                                            if video_url:
                                                images.append({
                                                    "url": video_url,
                                                    "title": "Video 1",
                                                    "thumbnail": post.get("image_versions2", {}).get("candidates", [{}])[0].get("url"),
                                                    "width": best_video.get("width"),
                                                    "height": best_video.get("height"),
                                                    "source": "instagram_api",
                                                    "isVideo": True
                                                })
                                    else:
                                        img_versions = post.get("image_versions2", {})
                                        candidates = img_versions.get("candidates", [])
                                        best = best_candidate(candidates)
                                        item_data = candidate_item(best, "Image 1", "instagram_api") if best else None
                                        if item_data:
                                            images.append(item_data)
                                if images:
                                    caption_text = post.get("caption", {}).get("text", "Instagram Post") if post.get("caption") else "Instagram Post"
                                    title_text = caption_text.split("\n")[0][:100] or "Instagram Post"
                    except Exception:
                        pass

                    # Attempt 2: Call web JSON endpoint (?__a=1&__d=dis)
                    if not images:
                        headers_web = {
                            "User-Agent": (
                                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                                "AppleWebKit/537.36 (KHTML, like Gecko) "
                                "Chrome/124.0.0.0 Safari/537.36"
                            ),
                            "Accept-Language": "en-US,en;q=0.9",
                            "Referer": "https://www.instagram.com/",
                        }
                        req_json = urllib.request.Request(
                            f"https://www.instagram.com/p/{shortcode}/?__a=1&__d=dis",
                            headers=headers_web
                        )
                        try:
                            with _urlopen(req_json, timeout=10) as response:
                                res_data = json.loads(response.read().decode("utf-8"))
                                media_data = find_shortcode_media(res_data)
                                if not media_data and res_data.get("items"):
                                    media_data = res_data["items"][0]
                                if media_data:
                                    if "carousel_media" in media_data or "image_versions2" in media_data:
                                        carousel = media_data.get("carousel_media", [])
                                        if carousel:
                                            for idx, item in enumerate(carousel):
                                                if item.get("media_type") == 2:  # video
                                                    video_versions = item.get("video_versions", [])
                                                    if video_versions:
                                                        best_video = max(video_versions, key=lambda v: (v.get("width") or 0) * (v.get("height") or 0))
                                                        video_url = best_video.get("url")
                                                        if video_url:
                                                            images.append({
                                                                "url": video_url,
                                                                "title": f"Video {idx + 1}",
                                                                "thumbnail": item.get("image_versions2", {}).get("candidates", [{}])[0].get("url"),
                                                                "width": best_video.get("width"),
                                                                "height": best_video.get("height"),
                                                                "source": "instagram_web_json",
                                                                "isVideo": True
                                                            })
                                                    continue
                                                img_versions = item.get("image_versions2", {})
                                                candidates = img_versions.get("candidates", [])
                                                best = best_candidate(candidates)
                                                item_data = candidate_item(best, f"Image {idx + 1}", "instagram_web_json") if best else None
                                                if item_data:
                                                    images.append(item_data)
                                        else:
                                            if media_data.get("media_type") == 2:  # video
                                                video_versions = media_data.get("video_versions", [])
                                                if video_versions:
                                                    best_video = max(video_versions, key=lambda v: (v.get("width") or 0) * (v.get("height") or 0))
                                                    video_url = best_video.get("url")
                                                    if video_url:
                                                        images.append({
                                                            "url": video_url,
                                                            "title": "Video 1",
                                                            "thumbnail": media_data.get("image_versions2", {}).get("candidates", [{}])[0].get("url"),
                                                            "width": best_video.get("width"),
                                                            "height": best_video.get("height"),
                                                            "source": "instagram_web_json",
                                                            "isVideo": True
                                                        })
                                            else:
                                                img_versions = media_data.get("image_versions2", {})
                                                candidates = img_versions.get("candidates", [])
                                                best = best_candidate(candidates)
                                                item_data = candidate_item(best, "Image 1", "instagram_web_json") if best else None
                                                if item_data:
                                                    images.append(item_data)
                                    else:
                                        images = parse_from_media_data(media_data)

                                    if images:
                                        caption_text = ""
                                        if isinstance(media_data, dict):
                                            caption_text = media_data.get("caption", {}).get("text", "") or media_data.get("title", "")
                                            if not caption_text and "edge_media_to_caption" in media_data:
                                                edges = media_data["edge_media_to_caption"].get("edges", [])
                                                if edges:
                                                    caption_text = edges[0].get("node", {}).get("text", "")
                                        title_text = caption_text.split("\n")[0][:100] or "Instagram Post"
                        except Exception:
                            pass

                    # Attempt 3: Fetch HTML page and parse JSON from scripts
                    if not images:
                        headers_web = {
                            "User-Agent": (
                                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                                "AppleWebKit/537.36 (KHTML, like Gecko) "
                                "Chrome/124.0.0.0 Safari/537.36"
                            ),
                            "Accept-Language": "en-US,en;q=0.9",
                        }
                        req_html = urllib.request.Request(url, headers=headers_web)
                        try:
                            with _urlopen(req_html, timeout=10) as response:
                                html_bytes = response.read()
                                content_type = response.headers.get("Content-Type", "")
                                charset = "utf-8"
                                if "charset=" in content_type:
                                    charset = content_type.split("charset=")[-1].split(";")[0].strip()
                                try:
                                    html_text = html_bytes.decode(charset, errors="replace")
                                except Exception:
                                    html_text = html_bytes.decode("utf-8", errors="replace")

                                title_match = re.search(r"<title[^>]*>(.*?)</title>", html_text, re.IGNORECASE | re.DOTALL)
                                if title_match:
                                    title_text = title_match.group(1).strip()

                                def _extract_json_block(text: str, start_pos: int) -> str | None:
                                    if start_pos < 0 or start_pos >= len(text):
                                        return None
                                    depth = 0
                                    in_str = False
                                    escape = False
                                    begin = None
                                    for i in range(start_pos, len(text)):
                                        ch = text[i]
                                        if escape:
                                            escape = False
                                            continue
                                        if ch == '\\' and in_str:
                                            escape = True
                                            continue
                                        if ch == '"' and not escape:
                                            in_str = not in_str
                                            continue
                                        if in_str:
                                            continue
                                        if ch == '{':
                                            if depth == 0:
                                                begin = i
                                            depth += 1
                                        elif ch == '}':
                                            depth -= 1
                                            if depth == 0 and begin is not None:
                                                return text[begin:i + 1]
                                    return None

                                script_contents = re.findall(r'<script[^>]*>(.*?)</script>', html_text, re.DOTALL)
                                parsed_jsons = []
                                for content in script_contents:
                                    if 'display_url' in content or 'shortcode_media' in content or '__INITIAL_STATE__' in content:
                                        # Try exact assignments first
                                        for prefix in ['window.__INITIAL_STATE__ = ', 'window._sharedData = ', 'window.__additionalDataLoaded']:
                                            pos = content.find(prefix)
                                            if pos >= 0:
                                                block = _extract_json_block(content, pos + len(prefix))
                                                if block:
                                                    try:
                                                        parsed_jsons.append(json.loads(block))
                                                        continue
                                                    except Exception:
                                                        pass
                                        # Fallback: try extracting any JSON-like block from the script
                                        json_raw_match = re.search(r'(\{.*\})', content)
                                        if json_raw_match:
                                            block = _extract_json_block(content, json_raw_match.start(1))
                                            if block:
                                                try:
                                                    parsed_jsons.append(json.loads(block))
                                                except Exception:
                                                    pass

                                for p_json in parsed_jsons:
                                    media_data = find_shortcode_media(p_json)
                                    if media_data:
                                        images = parse_from_media_data(media_data)
                                        if images:
                                            break

                        except Exception:
                            pass

                    if images:
                        return {
                            "title": title_text,
                            "platform": "Instagram",
                            "items": unique_image_items(images)
                        }
                    raise ValueError("Could not access the full-size Instagram image. This post may require login or cookies.")

            class ImageParser(HTMLParser):
                def __init__(self, base_url: str):
                    super().__init__()
                    self.base_url = base_url
                    self.images: list[dict[str, Any]] = []

                def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
                    if tag == "img":
                        src = None
                        alt = ""
                        for name, value in attrs:
                            if name == "src":
                                src = value
                            elif name == "alt":
                                alt = value or ""
                        if src and not src.startswith("data:"):
                            abs_url = urljoin(self.base_url, src)
                            parsed = urlparse(abs_url)
                            path = parsed.path.lower()
                            is_common_ext = any(path.endswith(ext) for ext in [".jpg", ".jpeg", ".png", ".webp", ".gif"])
                            is_static_or_tracker = any(part in abs_url.lower() for part in [
                                "pixel", "spacer", "tracker", "analytics", "advertisement",
                                "/static/", "/assets/", "logo", "spinner", "loading",
                                "icon", "avatar", "rsrc.php", "badge", "button",
                                "profile", "thumbnail", "emoji", "reaction", "favicon",
                                "transparent", "blank",
                            ])
                            if is_common_ext and not is_static_or_tracker:
                                self.images.append({
                                    "url": abs_url,
                                    "title": alt.strip() or f"Image {len(self.images) + 1}",
                                    "thumbnail": abs_url,
                                    "isVideo": False,
                                })
                    elif tag == "meta":
                        property_val = None
                        content_val = None
                        for name, value in attrs:
                          if name == "property" or name == "name":
                              property_val = value
                          elif name == "content":
                              content_val = value
                        if property_val in {"og:image", "twitter:image"} and content_val:
                            abs_url = urljoin(self.base_url, content_val)
                            is_static_or_tracker = any(part in abs_url.lower() for part in [
                                "pixel", "spacer", "tracker", "analytics", "advertisement",
                                "/static/", "/assets/", "logo", "spinner", "loading",
                                "icon", "avatar", "rsrc.php", "badge", "button"
                            ])
                            if not is_static_or_tracker:
                                if not any(img["url"] == abs_url for img in self.images):
                                    self.images.append({
                                        "url": abs_url,
                                        "title": f"Feature Image {len(self.images) + 1}",
                                        "thumbnail": abs_url,
                                        "isVideo": False,
                                    })

            # Generate URL candidates to try
            urls_to_try = [url]
            parsed_origin = urlparse(url)
            if "instagram.com" in parsed_origin.netloc.lower():
                cleaned_path = parsed_origin.path
                urls_to_try.insert(0, f"https://ddinstagram.com{cleaned_path}")
                urls_to_try.insert(1, f"https://fixinstagram.com{cleaned_path}")
            elif "twitter.com" in parsed_origin.netloc.lower() or "x.com" in parsed_origin.netloc.lower():
                cleaned_path = parsed_origin.path
                urls_to_try.insert(0, f"https://fxtwitter.com{cleaned_path}")
                urls_to_try.insert(1, f"https://vxtwitter.com{cleaned_path}")
            elif "pinterest.com" in parsed_origin.netloc.lower() or "pinterest.co.uk" in parsed_origin.netloc.lower():
                pin_match = re.search(r"/pin/(\d+)", parsed_origin.path)
                if pin_match:
                    pin_id = pin_match.group(1)
                    urls_to_try.insert(0, f"https://assets.pinterest.com/ext/embed.html?id={pin_id}")
            elif "pin.it" in parsed_origin.netloc.lower():
                try:
                    req_head = urllib.request.Request(
                        url,
                        headers={
                            "User-Agent": (
                                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                                "AppleWebKit/537.36 (KHTML, like Gecko) "
                                "Chrome/124.0.0.0 Safari/537.36"
                            )
                        },
                        method="HEAD"
                    )
                    with _urlopen(req_head, timeout=5) as resp:
                        resolved_url = resp.geturl()
                        resolved_parsed = urlparse(resolved_url)
                        pin_match = re.search(r"/pin/(\d+)", resolved_parsed.path)
                        if pin_match:
                            pin_id = pin_match.group(1)
                            urls_to_try.insert(0, f"https://assets.pinterest.com/ext/embed.html?id={pin_id}")
                except Exception:
                    pass

            html_text = ""
            for try_url in urls_to_try:
                try:
                    req = urllib.request.Request(
                        try_url,
                        headers={
                            "User-Agent": (
                                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                                "AppleWebKit/537.36 (KHTML, like Gecko) "
                                "Chrome/124.0.0.0 Safari/537.36"
                            )
                        }
                    )
                    with _urlopen(req, timeout=10) as response:
                        html_bytes = response.read()
                        content_type = response.headers.get("Content-Type", "")
                        charset = "utf-8"
                        if "charset=" in content_type:
                            charset = content_type.split("charset=")[-1].split(";")[0].strip()
                        try:
                            html_text = html_bytes.decode(charset, errors="replace")
                        except Exception:
                            html_text = html_bytes.decode("utf-8", errors="replace")

                        title_match = re.search(r"<title[^>]*>(.*?)</title>", html_text, re.IGNORECASE | re.DOTALL)
                        page_title = title_match.group(1).strip() if title_match else "Scraped Webpage"

                        parser = ImageParser(try_url)
                        parser.feed(html_text)

                        seen = set()
                        unique_images = []
                        for img in parser.images:
                            if img["url"] not in seen:
                                seen.add(img["url"])
                                unique_images.append(img)

                        if unique_images:
                            return {
                                "title": page_title,
                                "platform": urlparse(url).netloc or "Webpage",
                                "items": unique_images
                            }
                except Exception:
                    continue

            # Fallback: retry Instagram with bot user-agents (they return og:image)
            if "instagram.com" in parsed_origin.netloc.lower():
                bot_agents = [
                    "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
                    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
                    "Twitterbot/1.0",
                ]
                for ua in bot_agents:
                    try:
                        req = urllib.request.Request(
                            url,
                            headers={"User-Agent": ua}
                        )
                        with _urlopen(req, timeout=10) as response:
                            html_bytes = response.read()
                            content_type = response.headers.get("Content-Type", "")
                            charset = "utf-8"
                            if "charset=" in content_type:
                                charset = content_type.split("charset=")[-1].split(";")[0].strip()
                            try:
                                html_text = html_bytes.decode(charset, errors="replace")
                            except Exception:
                                html_text = html_bytes.decode("utf-8", errors="replace")
                            parser = ImageParser(url)
                            parser.feed(html_text)
                            if parser.images:
                                return {
                                    "title": "Instagram Image",
                                    "platform": "Instagram",
                                    "items": unique_image_items(parser.images)
                                }
                    except Exception:
                        continue

            return {
                "title": "Scraped Webpage",
                "platform": urlparse(url).netloc or "Webpage",
                "items": []
            }

        return await asyncio.to_thread(run)

    async def trim(self, download_id: str, start_time: float, end_time: float) -> dict[str, Any]:
        state = self.states.get(download_id)
        if state is None or state.status != "completed" or not state.filename:
            raise ValueError("Download is not completed or has no file.")

        original_path = settings.storage_dir / download_id / state.filename
        if not original_path.exists():
            raise FileNotFoundError(f"Original file not found at {original_path}")

        suffix = original_path.suffix
        temp_trimmed_filename = f"temp_trimmed_{state.filename}"
        temp_trimmed_path = settings.storage_dir / download_id / temp_trimmed_filename

        cmd = [
            "ffmpeg",
            "-y",
            "-ss", str(start_time),
            "-to", str(end_time),
            "-i", str(original_path),
            "-c", "copy",
            str(temp_trimmed_path)
        ]

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await process.communicate()

        if process.returncode != 0:
            cmd_reencode = [
                "ffmpeg",
                "-y",
                "-ss", str(start_time),
                "-to", str(end_time),
                "-i", str(original_path),
                str(temp_trimmed_path)
            ]
            process_re = await asyncio.create_subprocess_exec(
                *cmd_reencode,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout_re, stderr_re = await process_re.communicate()
            if process_re.returncode != 0:
                raise RuntimeError(f"FFmpeg failed: {stderr_re.decode()}")

        if temp_trimmed_path.exists():
            original_path.unlink()
            temp_trimmed_path.rename(original_path)

        return {
            "downloadId": download_id,
            "fileUrl": state.file_url,
            "filename": state.filename,
        }


download_manager = DownloadManager()


def map_extract_response(info: dict[str, Any]) -> dict[str, Any]:
    if "qualities" in info and "audio_formats" in info:
        return info
    formats = info.get("formats") or []
    video_formats: list[dict[str, Any]] = []
    audio_formats: list[dict[str, Any]] = []
    seen_video: set[str] = set()
    seen_audio: set[str] = set()

    for fmt in formats:
        height = fmt.get("height")
        vcodec = fmt.get("vcodec")
        acodec = fmt.get("acodec")
        ext = fmt.get("ext")
        format_id = str(fmt.get("format_id") or "")
        if height and vcodec != "none":
            label = f"{height}p"
            if label not in seen_video:
                seen_video.add(label)
                video_formats.append({
                    "id": format_id or label,
                    "label": label,
                    "ext": ext,
                    "height": height,
                    "width": fmt.get("width"),
                    "filesize": fmt.get("filesize") or fmt.get("filesize_approx"),
                    "acodec": acodec,
                    "vcodec": vcodec,
                })
        if acodec and acodec != "none" and vcodec == "none":
            label = fmt.get("format_note") or fmt.get("abr") or "audio"
            key = str(label)
            if key not in seen_audio:
                seen_audio.add(key)
                audio_formats.append({
                    "id": format_id or key,
                    "label": str(label),
                    "ext": ext,
                    "filesize": fmt.get("filesize") or fmt.get("filesize_approx"),
                    "acodec": acodec,
                    "vcodec": vcodec,
                })

    if not video_formats:
        video_formats.append({"id": "best", "label": "Best", "ext": info.get("ext")})
    if not audio_formats:
        audio_formats.append({"id": "bestaudio", "label": "Best audio", "ext": "mp3"})

    duration = info.get("duration")
    duration_text = None
    if isinstance(duration, int):
        mins, secs = divmod(duration, 60)
        duration_text = f"{mins}:{secs:02d}"

    return {
        "title": info.get("title") or "Untitled",
        "thumbnail": info.get("thumbnail"),
        "duration": duration_text,
        "platform": info.get("extractor_key") or info.get("extractor") or "Public source",
        "qualities": sorted(video_formats, key=lambda item: item.get("height") or 0, reverse=True),
        "audio_formats": audio_formats,
    }
