from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from slowapi import Limiter
from slowapi.middleware import SlowAPIMiddleware
from slowapi.util import get_remote_address
import asyncio

from .config import settings
from .downloads import download_manager, map_extract_response
from .models import (
    DownloadRequest,
    DownloadResponse,
    ExtractRequest,
    ExtractResponse,
    StatusResponse,
    PlaylistExtractRequest,
    PlaylistExtractResponse,
    TrimRequest,
    TrimResponse,
    CookiesRequest,
    CookiesResponse,
)

limiter = Limiter(key_func=get_remote_address)

app = FastAPI(title="Duck Downloader API", version="1.0.0")
app.state.limiter = limiter
app.add_middleware(SlowAPIMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
app.mount("/files", StaticFiles(directory=settings.storage_dir), name="files")


def public_error(exc: Exception) -> str:
    message = str(exc).strip()
    if not message:
        message = f"{type(exc).__name__}: backend failed while processing this request."
    if "full-size Instagram image" in message:
        return message
    if "Sign in to confirm" in message or "not a bot" in message:
        return (
            "This source blocked the request with a bot or sign-in check. "
            "Rebuild the backend with the latest yt-dlp, or configure DUCK_YTDLP_COOKIES "
            "with a cookies.txt file for sources that require browser verification."
        )
    if "UNEXPECTED_EOF_WHILE_READING" in message or "Unable to download API page" in message:
        return (
            "YouTube interrupted the backend connection while checking this video. "
            "Restart the backend with the latest deployment, then try again. "
            "If it still happens, this source may be blocking Hugging Face's network."
        )
    if any(part in message.lower() for part in ["private", "drm", "copyright", "paywall"]):
        return (
            "Duck can only download public media links supported by yt-dlp. "
            "Private, DRM-protected, paywalled, or restricted content is not supported."
        )
    if "facebook" in message.lower() and (
        "registered users" in message.lower()
        or "cookies" in message.lower()
        or "authentication" in message.lower()
    ):
        return "This Facebook photo is not public or requires login."
    if "registered users" in message.lower() or "cookies" in message.lower() or "authentication" in message.lower():
        return (
            "This source requires a logged-in account. "
            "Configure DUCK_YTDLP_COOKIES with a cookies.txt file for authentication."
        )
    if "Unsupported URL" in message:
        return (
            "This source is not supported by yt-dlp or the URL is not public. "
            "Try a direct public post, video, or audio link."
        )
    return message


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/cookies", response_model=CookiesResponse)
async def get_cookies() -> CookiesResponse:
    from pathlib import Path
    cookies_path = settings.storage_dir / "cookies.txt"
    active = settings.resolved_cookies_file is not None
    size = cookies_path.stat().st_size if cookies_path.exists() else 0
    filename = settings.resolved_cookies_file
    if filename:
        filename = Path(filename).name
    return CookiesResponse(active=active, size=size, filename=filename)


@app.post("/api/cookies", response_model=CookiesResponse)
async def set_cookies(body: CookiesRequest) -> CookiesResponse:
    cookies_path = settings.storage_dir / "cookies.txt"
    try:
        cookies_path.write_text(body.cookies, encoding="utf-8")
        active = settings.resolved_cookies_file is not None
        size = cookies_path.stat().st_size
        filename = settings.resolved_cookies_file
        if filename:
            from pathlib import Path
            filename = Path(filename).name
        return CookiesResponse(active=active, size=size, filename=filename)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Failed to save cookies: {exc}") from exc


@app.delete("/api/cookies", response_model=CookiesResponse)
async def delete_cookies() -> CookiesResponse:
    cookies_path = settings.storage_dir / "cookies.txt"
    if cookies_path.exists():
        cookies_path.unlink()
    active = settings.resolved_cookies_file is not None
    return CookiesResponse(active=active, size=0, filename=None)


def normalize_url(url: str) -> str:
    val = str(url)
    lower = val.lower()
    if "threads.com" in lower:
        val = val.replace("threads.com", "threads.net")
        val = val.replace("www.threads.com", "www.threads.net")
    return val


@app.post("/api/extract", response_model=ExtractResponse)
@limiter.limit("30/minute")
async def extract(request: Request, body: ExtractRequest) -> dict:
    try:
        url = normalize_url(body.url)
        info = await download_manager.extract(url)
        return map_extract_response(info)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.post("/api/playlist/extract", response_model=PlaylistExtractResponse)
@limiter.limit("20/minute")
async def extract_playlist(
    request: Request, body: PlaylistExtractRequest
) -> PlaylistExtractResponse:
    try:
        url = normalize_url(body.url)
        info = await download_manager.extract_playlist(url)
        return PlaylistExtractResponse(**info)
    except Exception as exc:
        try:
            url = normalize_url(body.url)
            info = await download_manager.extract_images(url)
            if info["items"]:
                return PlaylistExtractResponse(**info)
        except Exception:
            pass
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.post("/api/download", response_model=DownloadResponse)
@limiter.limit("20/minute")
async def download(request: Request, body: DownloadRequest) -> DownloadResponse:
    try:
        url = normalize_url(body.url)
        download_id = await download_manager.start(
            url,
            body.type,
            body.quality,
            body.premium_no_watermark,
            body.remove_music,
        )
        return DownloadResponse(downloadId=download_id)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.get("/api/status/{download_id}", response_model=StatusResponse)
async def status(download_id: str) -> StatusResponse:
    state = download_manager.status(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/download/{download_id}/pause", response_model=StatusResponse)
async def pause_download(download_id: str) -> StatusResponse:
    state = await download_manager.pause(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/download/{download_id}/resume", response_model=StatusResponse)
async def resume_download(download_id: str) -> StatusResponse:
    state = await download_manager.resume(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/download/{download_id}/cancel", response_model=StatusResponse)
async def cancel_download(download_id: str) -> StatusResponse:
    state = await download_manager.cancel(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/trim", response_model=TrimResponse)
async def trim_file(body: TrimRequest) -> TrimResponse:
    try:
        res = await download_manager.trim(
            download_id=body.download_id,
            start_time=body.start_time,
            end_time=body.end_time,
        )
        return TrimResponse(**res)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.websocket("/ws/download/{download_id}")
async def download_ws(websocket: WebSocket, download_id: str) -> None:
    await websocket.accept()
    state = download_manager.status(download_id)
    if state is None:
        await websocket.send_json({"status": "failed", "progress": 0, "error": "Download not found"})
        await websocket.close()
        return

    queue: asyncio.Queue[dict] = asyncio.Queue()
    state.subscribers.add(queue)
    await websocket.send_json(state.snapshot())
    try:
        while True:
            payload = await queue.get()
            await websocket.send_json(payload)
            if payload.get("status") in {"completed", "failed", "cancelled", "paused"}:
                await websocket.close()
                return
    except WebSocketDisconnect:
        return
    finally:
        state.subscribers.discard(queue)
