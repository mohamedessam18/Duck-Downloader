from __future__ import annotations
from enum import Enum

try:
    from pydantic import BaseModel, Field, HttpUrl
except ImportError:
    class BaseModel:
        def __init__(self, **kwargs):
            for k, v in kwargs.items():
                setattr(self, k, v)
        def model_dump(self, *args, **kwargs):
            return self.__dict__
    def Field(default=None, **kwargs):
        return default
    HttpUrl = str


class DownloadType(str, Enum):
    video = "video"
    audio = "audio"
    image = "image"


class CookiesResponse(BaseModel):
    """Whether the *operator* configured cookies, via DUCK_YTDLP_COOKIES.

    It says nothing about any user's session. Users' cookies arrive with the
    request that needs them and are deleted with it, so there is no per-user
    state here to report.
    """

    active: bool
    size: int
    filename: str | None = None


class ExtractRequest(BaseModel):
    url: HttpUrl
    # The caller's own cookies for this link's site, in Netscape format.
    #
    # Sent per request rather than stored, because a server-side cookie jar on
    # a shared deployment is a shared login: see app/cookies.py.
    cookies: str | None = None


class DownloadRequest(BaseModel):
    url: HttpUrl
    type: DownloadType
    quality: str | None = None
    premium_no_watermark: bool = Field(default=False, alias="premiumNoWatermark")
    remove_music: bool = Field(default=False, alias="removeMusic")
    cookies: str | None = None


class FormatInfo(BaseModel):
    id: str
    label: str
    ext: str | None = None
    height: int | None = None
    width: int | None = None
    filesize: int | None = None
    acodec: str | None = None
    vcodec: str | None = None


class ExtractResponse(BaseModel):
    title: str
    thumbnail: str | None = None
    duration: str | None = None
    platform: str
    qualities: list[FormatInfo]
    audio_formats: list[FormatInfo]


class DownloadResponse(BaseModel):
    downloadId: str


class StatusResponse(BaseModel):
    progress: int
    speed: str | None = None
    eta: str | None = None
    status: str
    fileUrl: str | None = None
    filename: str | None = None
    error: str | None = None


class TrimRequest(BaseModel):
    downloadId: str = Field(alias="downloadId")
    startTime: float = Field(alias="startTime")
    endTime: float = Field(alias="endTime")


class TrimResponse(BaseModel):
    downloadId: str = Field(alias="downloadId")
    fileUrl: str = Field(alias="fileUrl")
    filename: str = Field(alias="filename")


class PlaylistItemInfo(BaseModel):
    url: str
    title: str
    thumbnail: str | None = None
    width: int | None = None
    height: int | None = None
    source: str | None = None
    isPreview: bool = Field(default=False, alias="isPreview")
    isVideo: bool = Field(default=False, alias="isVideo")

class PlaylistExtractRequest(BaseModel):
    url: HttpUrl
    cookies: str | None = None


class PlaylistExtractResponse(BaseModel):
    title: str
    platform: str
    items: list[PlaylistItemInfo]


class AdReportRequest(BaseModel):
    """One user's report about an ad they were shown.

    Every field is optional except the reason. A report that arrives without
    its technical context is still worth having — the person may have removed
    it on the page, which is their right — and refusing it would trade real
    signal for tidiness.
    """

    reason: str
    details: str | None = None
    adFormat: str | None = None
    appVersion: str | None = None
    platform: str | None = None
    locale: str | None = None
    seenAt: str | None = None


class AdReportResponse(BaseModel):
    accepted: bool
    id: str
