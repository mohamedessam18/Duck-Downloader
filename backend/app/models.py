from enum import Enum
from pydantic import BaseModel, Field, HttpUrl


class DownloadType(str, Enum):
    video = "video"
    audio = "audio"
    image = "image"


class CookiesRequest(BaseModel):
    cookies: str


class CookiesResponse(BaseModel):
    active: bool
    size: int
    filename: str | None = None


class ExtractRequest(BaseModel):
    url: HttpUrl


class DownloadRequest(BaseModel):
    url: HttpUrl
    type: DownloadType
    quality: str | None = None
    premium_no_watermark: bool = Field(default=False, alias="premiumNoWatermark")
    remove_music: bool = Field(default=False, alias="removeMusic")


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


class PlaylistExtractResponse(BaseModel):
    title: str
    platform: str
    items: list[PlaylistItemInfo]
