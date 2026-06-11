from enum import Enum
from pydantic import BaseModel, Field, HttpUrl


class DownloadType(str, Enum):
    video = "video"
    audio = "audio"


class ExtractRequest(BaseModel):
    url: HttpUrl


class DownloadRequest(BaseModel):
    url: HttpUrl
    type: DownloadType
    quality: str | None = None
    premium_no_watermark: bool = Field(default=False, alias="premiumNoWatermark")
    license_key: str | None = Field(default=None, alias="licenseKey")


class LicenseRequest(BaseModel):
    license_key: str = Field(alias="licenseKey")


class LicenseResponse(BaseModel):
    active: bool


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
