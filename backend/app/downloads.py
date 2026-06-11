import asyncio
import re
import shutil
import sys
import uuid
from pathlib import Path
from typing import Any

from yt_dlp import YoutubeDL

from .config import settings
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
    ) -> None:
        self.download_id = download_id
        self.url = url
        self.download_type = download_type
        self.quality = quality
        self.premium_no_watermark = premium_no_watermark
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


class DownloadManager:
    def __init__(self) -> None:
        self.states: dict[str, DownloadState] = {}
        self.tasks: dict[str, asyncio.Task[None]] = {}
        self.semaphore = asyncio.Semaphore(settings.max_concurrent_downloads)

    async def extract(self, url: str) -> dict[str, Any]:
        validate_public_url(url)

        def run() -> dict[str, Any]:
            with YoutubeDL(self._base_ydl_options(skip_download=True)) as ydl:
                return ydl.extract_info(url, download=False)

        return await asyncio.to_thread(run)

    def _base_ydl_options(self, *, skip_download: bool = False) -> dict[str, Any]:
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
            "extractor_args": {
                "youtube": {
                    "player_client": ["android", "web"],
                },
            },
        }
        if settings.cookies_file:
            opts["cookiefile"] = settings.cookies_file
        return opts

    async def start(
        self,
        url: str,
        download_type: DownloadType,
        quality: str | None,
        premium_no_watermark: bool = False,
    ) -> str:
        validate_public_url(url)
        download_id = uuid.uuid4().hex
        state = DownloadState(download_id, url, download_type, quality, premium_no_watermark)
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
                await self._publish(state)
        finally:
            state.process = None
            if state.status == "cancelled":
                self._cleanup_download_dir(download_id)
            if self.tasks.get(download_id) is asyncio.current_task():
                self.tasks.pop(download_id, None)

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
                ext = "mp3" if download_type == DownloadType.audio else "mp4"
                final_path = ensure_inside(target_dir, target_dir / f"{title}.{ext}")
                if produced.resolve() != final_path.resolve():
                    produced.replace(final_path)
                state.filename = final_path.name
                state.file_url = f"{settings.public_base_url}/files/{state.download_id}/{final_path.name}"
                return
            except DownloadInterrupted:
                raise
            except Exception as exc:
                last_error = exc
                if not prefer_tiktok_no_watermark:
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
            details = "\n".join(output[-6:]).strip()
            raise RuntimeError(details or f"yt-dlp failed with exit code {return_code}.")

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
            "--continue",
            "--restrict-filenames",
            "--windows-filenames",
            "--user-agent",
            (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            "--add-header",
            "Accept-Language:en-US,en;q=0.9",
            "--extractor-args",
            "youtube:player_client=android,web",
            "-f",
            format_selector,
            "-o",
            str(target_dir / "%(title).140s.%(ext)s"),
        ]
        if settings.cookies_file:
            args.extend(["--cookies", settings.cookies_file])
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
        if quality:
            numeric = "".join(ch for ch in quality if ch.isdigit())
            if numeric:
                return (
                    f"bestvideo[height<={numeric}][ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/"
                    f"best[height<={numeric}][ext=mp4]/"
                    f"bestvideo[height<={numeric}]+bestaudio/best[height<={numeric}]/best"
                )
        return "bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/bestvideo+bestaudio/best"

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


download_manager = DownloadManager()


def map_extract_response(info: dict[str, Any]) -> dict[str, Any]:
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
