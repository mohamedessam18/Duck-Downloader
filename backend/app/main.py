from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse
from fastapi.openapi.docs import get_swagger_ui_html, get_redoc_html
from slowapi import Limiter
from slowapi.middleware import SlowAPIMiddleware
from slowapi.util import get_remote_address
import asyncio
from pathlib import Path

from .config import settings
from . import ad_reports
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
    AdReportRequest,
    AdReportResponse,
)

limiter = Limiter(key_func=get_remote_address)

# Load index.html content once at startup
static_dir = Path(__file__).resolve().parent.parent / "static"
index_html_path = static_dir / "index.html"
index_html_content = ""
if index_html_path.exists():
    index_html_content = index_html_path.read_text(encoding="utf-8")

tags_metadata = [
    {
        "name": "System Health",
        "description": "API service operational status and health checks.",
    },
    {
        "name": "Cookies Configuration",
        "description": "Authentication settings for downloading from private or age-restricted links.",
    },
    {
        "name": "Metadata Extraction",
        "description": "Analyze URL links to extract titles, thumbnails, and list of available qualities.",
    },
    {
        "name": "Downloads Control",
        "description": "Initiate, pause, resume, cancel, and track media download progress.",
    },
    {
        "name": "Media Editing",
        "description": "Perform operations on downloaded media files like trimming duration.",
    },
]

app = FastAPI(
    title="Duck Downloader API",
    version="1.0.0",
    description="Backend API Gateway for Duck Downloader client applications. Supports video, audio, playlist, and image downloads.",
    openapi_tags=tags_metadata,
    docs_url=None,
    redoc_url=None,
)
app.state.limiter = limiter
app.add_middleware(SlowAPIMiddleware)


# Content Negotiation Middleware to serve HTML dashboard for browser requests on all paths
@app.middleware("http")
async def content_negotiation_middleware(request: Request, call_next):
    accept = request.headers.get("accept", "")
    path = request.url.path
    if "text/html" in accept and not path.startswith("/files") and path != "/openapi.json":
        return HTMLResponse(content=index_html_content)
    return await call_next(request)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
app.mount("/files", StaticFiles(directory=settings.storage_dir), name="files")


@app.get("/docs", include_in_schema=False)
async def custom_swagger_ui_html():
    response = get_swagger_ui_html(
        openapi_url=app.openapi_url,
        title=app.title + " - Interactive API Docs",
        oauth2_redirect_url=app.swagger_ui_oauth2_redirect_url,
        swagger_js_url="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js",
        swagger_css_url="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css",
    )
    html_content = response.body.decode("utf-8")
    dark_theme_css = '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-themes@3.0.1/themes/3.x/theme-monokai.css">'
    html_content = html_content.replace("</head>", f"{dark_theme_css}</head>")
    return HTMLResponse(content=html_content)


@app.get("/redoc", include_in_schema=False)
async def custom_redoc_ui_html():
    return get_redoc_html(
        openapi_url=app.openapi_url,
        title=app.title + " - Redoc API Docs",
        redoc_js_url="https://cdn.jsdelivr.net/npm/redoc@next/bundles/redoc.standalone.js",
    )


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


@app.get("/health", tags=["System Health"])
async def health() -> dict[str, str]:
    """
    Check API gateway status.
    Returns 'status: ok' if the service is operational.
    """
    return {"status": "ok"}


@app.get("/api/cookies", response_model=CookiesResponse, tags=["Cookies Configuration"])
async def get_cookies() -> CookiesResponse:
    """
    Get active cookies file status.
    Returns if cookies.txt exists, its size, and the filename.
    """
    from pathlib import Path
    cookies_path = settings.storage_dir / "cookies.txt"
    active = settings.resolved_cookies_file is not None
    size = cookies_path.stat().st_size if cookies_path.exists() else 0
    filename = settings.resolved_cookies_file
    if filename:
        filename = Path(filename).name
    return CookiesResponse(active=active, size=size, filename=filename)


@app.post("/api/cookies", response_model=CookiesResponse, tags=["Cookies Configuration"])
async def set_cookies(body: CookiesRequest) -> CookiesResponse:
    """
    Upload cookies.txt configuration text.
    Allows authenticating requests to restricted platforms (e.g. YouTube private/age-gated videos).
    """
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


@app.delete("/api/cookies", response_model=CookiesResponse, tags=["Cookies Configuration"])
async def delete_cookies() -> CookiesResponse:
    """
    Delete the active cookies.txt configuration.
    Clears authentication cache for yt-dlp.
    """
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


@app.post("/api/extract", response_model=ExtractResponse, tags=["Metadata Extraction"])
@limiter.limit("30/minute")
async def extract(request: Request, body: ExtractRequest) -> dict:
    """
    Extract media metadata from URL.
    Retrieves titles, platform name, thumbnail, and the list of available qualities.
    """
    try:
        url = normalize_url(body.url)
        info = await download_manager.extract(url)
        return map_extract_response(info)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.post("/api/playlist/extract", response_model=PlaylistExtractResponse, tags=["Metadata Extraction"])
@limiter.limit("20/minute")
async def extract_playlist(
    request: Request, body: PlaylistExtractRequest
) -> PlaylistExtractResponse:
    """
    Extract playlist items and information.
    Parses a playlist URL (e.g. YouTube playlist, Instagram multi-post carousel) and returns item entries.
    """
    try:
        url = normalize_url(body.url)
        info = await download_manager.extract_playlist(url)
        return PlaylistExtractResponse(**info)
    except Exception as exc:
        try:
            url = normalize_url(body.url)
            from urllib.parse import urlparse
            parsed = urlparse(url)
            host = parsed.netloc.lower()
            if not any(domain in host for domain in ["youtube.com", "youtu.be", "tiktok.com", "instagram.com", "facebook.com", "fb.watch"]):
                info = await download_manager.extract_images(url)
                if info["items"]:
                    return PlaylistExtractResponse(**info)
        except Exception:
            pass
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.post("/api/download", response_model=DownloadResponse, tags=["Downloads Control"])
@limiter.limit("20/minute")
async def download(request: Request, body: DownloadRequest) -> DownloadResponse:
    """
    Initiate a download process for a given URL.
    Configures download type, requested quality, watermark removal, and audio strip settings.
    """
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


@app.get("/api/status/{download_id}", response_model=StatusResponse, tags=["Downloads Control"])
async def status(download_id: str) -> StatusResponse:
    """
    Retrieve live download status.
    Returns progress percentage, current download speed, ETA, and the resulting file URL on completion.
    """
    state = download_manager.status(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/download/{download_id}/pause", response_model=StatusResponse, tags=["Downloads Control"])
async def pause_download(download_id: str) -> StatusResponse:
    """
    Pause an active download process.
    """
    state = await download_manager.pause(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/download/{download_id}/resume", response_model=StatusResponse, tags=["Downloads Control"])
async def resume_download(download_id: str) -> StatusResponse:
    """
    Resume a paused download process.
    """
    state = await download_manager.resume(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/download/{download_id}/cancel", response_model=StatusResponse, tags=["Downloads Control"])
async def cancel_download(download_id: str) -> StatusResponse:
    """
    Cancel and delete an active download process.
    """
    state = await download_manager.cancel(download_id)
    if state is None:
        raise HTTPException(status_code=404, detail="Download not found")
    return StatusResponse(**state.snapshot())


@app.post("/api/trim", response_model=TrimResponse, tags=["Media Editing"])
async def trim_file(body: TrimRequest) -> TrimResponse:
    """
    Trim a completed downloaded media file.
    Clips duration between a custom start and end timestamp in seconds.
    """
    try:
        res = await download_manager.trim(
            download_id=body.download_id,
            start_time=body.start_time,
            end_time=body.end_time,
        )
        return TrimResponse(**res)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=public_error(exc)) from exc


@app.post("/api/ad-report", response_model=AdReportResponse, tags=["Ad Reports"])
@limiter.limit("6/minute")
async def submit_ad_report(request: Request, body: AdReportRequest) -> AdReportResponse:
    """Records a user's report about an ad.

    This is the developer's own record, not a channel to Google — AdMob has
    its own reporting on the ad itself. The value here is seeing the same
    complaint arrive repeatedly and having something concrete to act on in the
    AdMob console.

    Rate limited hard: there is nothing to gain from submitting a hundred of
    these, and an open write endpoint is an invitation.
    """
    record = ad_reports.build_record(
        reason=body.reason,
        details=body.details,
        ad_format=body.adFormat,
        app_version=body.appVersion,
        platform=body.platform,
        locale=body.locale,
        seen_at=body.seenAt,
    )
    try:
        ad_reports.append(record, settings.storage_dir)
    except Exception as exc:
        raise HTTPException(status_code=500, detail="Could not save the report.") from exc
    return AdReportResponse(accepted=True, id=record["id"])


@app.get("/api/ad-report", tags=["Ad Reports"])
async def read_ad_reports(request: Request, token: str = "") -> dict:
    """Reads the reports back. Owner only.

    Behind a token because these are complaints written by users, and an open
    list would publish them. Returns 404 rather than 401 when the token is
    unset or wrong, so the endpoint does not advertise that it exists.
    """
    expected = settings.ad_reports_token
    if not expected or token != expected:
        raise HTTPException(status_code=404, detail="Not found.")
    return ad_reports.summarise(settings.storage_dir)


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


# Serve static landing page and catch-all routes



@app.get("/", response_class=HTMLResponse, include_in_schema=False)
async def serve_home():
    return HTMLResponse(content=index_html_content)


@app.get("/{catchall:path}", response_class=HTMLResponse, include_in_schema=False)
async def catch_all(request: Request, catchall: str):
    lower_path = catchall.lower()
    if (
        lower_path.startswith("api/")
        or lower_path.startswith("files/")
        or lower_path == "openapi.json"
    ):
        raise HTTPException(status_code=404, detail="Not Found")
    return HTMLResponse(content=index_html_content)
