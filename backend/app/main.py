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
    LicenseRequest,
    LicenseResponse,
    StatusResponse,
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
    message = str(exc)
    if "Sign in to confirm" in message or "not a bot" in message:
        return (
            "This source blocked the request with a bot or sign-in check. "
            "Rebuild the backend with the latest yt-dlp, or configure DUCK_YTDLP_COOKIES "
            "with a cookies.txt file for sources that require browser verification."
        )
    if any(part in message.lower() for part in ["private", "drm", "copyright", "paywall"]):
        return (
            "Duck can only download public media links supported by yt-dlp. "
            "Private, DRM-protected, paywalled, or restricted content is not supported."
        )
    if "Unsupported URL" in message:
        return (
            "This source is not supported by yt-dlp or the URL is not public. "
            "Try a direct public post, video, or audio link."
        )
    return message


def is_valid_license(license_key: str | None) -> bool:
    if license_key is None:
        return False
    normalized = license_key.strip()
    return bool(normalized) and normalized in settings.pro_license_keys


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/extract", response_model=ExtractResponse)
@limiter.limit("30/minute")
async def extract(request: Request, body: ExtractRequest) -> dict:
    try:
        info = await download_manager.extract(str(body.url))
        return map_extract_response(info)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.post("/api/license/activate", response_model=LicenseResponse)
@limiter.limit("20/minute")
async def activate_license(request: Request, body: LicenseRequest) -> LicenseResponse:
    return LicenseResponse(active=is_valid_license(body.license_key))


@app.post("/api/license/verify", response_model=LicenseResponse)
@limiter.limit("20/minute")
async def verify_license(request: Request, body: LicenseRequest) -> LicenseResponse:
    return LicenseResponse(active=is_valid_license(body.license_key))


@app.post("/api/download", response_model=DownloadResponse)
@limiter.limit("20/minute")
async def download(request: Request, body: DownloadRequest) -> DownloadResponse:
    if body.premium_no_watermark and not is_valid_license(body.license_key):
        raise HTTPException(status_code=403, detail="A valid Pro license is required.")
    try:
        download_id = await download_manager.start(
            str(body.url),
            body.type,
            body.quality,
            body.premium_no_watermark,
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
