#!/usr/bin/env python3
"""Generate every app-icon variant from the single transparent duck artwork.

Run after changing `assets/images/branding/logo_launcher_square.png`:

    python3 tool/generate_icons.py
    dart run flutter_launcher_icons

Outputs, all into `assets/images/branding/`:

  icon_composed_dark.png   duck over the dark brand background  (default icon)
  icon_composed_light.png  duck over the light brand background (iOS light)
  icon_monochrome.png      white silhouette on transparent      (Android themed)
  icon_tinted.png          luminance-only greyscale             (iOS tinted)

Deliberately dependency-free: the machine this was written on had no Pillow and
no ImageMagick, and an icon pipeline that only runs where someone remembered to
`pip install` is a pipeline that rots. Everything here is stdlib zlib + struct,
which is all a straight 8-bit RGBA PNG actually needs.
"""

from __future__ import annotations

import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRANDING = os.path.join(ROOT, "assets", "images", "branding")
SOURCE = os.path.join(BRANDING, "logo_launcher_square.png")

# Brand backgrounds. Dark matches `ic_launcher_background` and
# `background_color_ios` so the generated icon and the adaptive-icon background
# cannot drift apart.
DARK_BG = (0x10, 0x11, 0x12)
LIGHT_BG = (0xF5, 0xF6, 0xF8)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


# ── decoding ────────────────────────────────────────────────────────────────


def read_png_rgba(path: str) -> tuple[int, int, bytearray]:
    """Return (width, height, RGBA bytes) for an 8-bit truecolour PNG."""
    with open(path, "rb") as handle:
        data = handle.read()

    if data[:8] != PNG_SIGNATURE:
        raise ValueError(f"{path} is not a PNG")

    width = height = None
    bit_depth = colour_type = None
    idat = bytearray()

    offset = 8
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset : offset + 4])
        kind = data[offset + 4 : offset + 8]
        body = data[offset + 8 : offset + 8 + length]
        offset += 12 + length  # length + type + body + crc

        if kind == b"IHDR":
            width, height, bit_depth, colour_type, comp, filt, interlace = (
                struct.unpack(">IIBBBBB", body)
            )
            if bit_depth != 8 or colour_type not in (2, 6):
                raise ValueError(
                    f"{path}: need an 8-bit RGB/RGBA PNG "
                    f"(got depth {bit_depth}, colour type {colour_type})"
                )
            if interlace:
                raise ValueError(f"{path}: interlaced PNGs are not supported")
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break

    if width is None:
        raise ValueError(f"{path}: no IHDR chunk")

    channels = 4 if colour_type == 6 else 3
    raw = zlib.decompress(bytes(idat))
    pixels = unfilter(raw, width, height, channels)

    if channels == 3:  # promote to RGBA
        rgba = bytearray(width * height * 4)
        for i in range(width * height):
            rgba[i * 4 : i * 4 + 3] = pixels[i * 3 : i * 3 + 3]
            rgba[i * 4 + 3] = 255
        pixels = rgba

    return width, height, pixels


def unfilter(raw: bytes, width: int, height: int, channels: int) -> bytearray:
    """Reverse the per-scanline PNG filters (spec section 9)."""
    stride = width * channels
    out = bytearray(stride * height)
    previous = bytearray(stride)
    pos = 0

    for row in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride

        if filter_type == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:  # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                up_left = previous[i - channels] if i >= channels else 0
                estimate = left + up - up_left
                da, db, dc = (
                    abs(estimate - left),
                    abs(estimate - up),
                    abs(estimate - up_left),
                )
                if da <= db and da <= dc:
                    predictor = left
                elif db <= dc:
                    predictor = up
                else:
                    predictor = up_left
                line[i] = (line[i] + predictor) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"unknown PNG filter type {filter_type}")

        out[row * stride : (row + 1) * stride] = line
        previous = line

    return out


# ── encoding ────────────────────────────────────────────────────────────────


def write_png_rgba(path: str, width: int, height: int, pixels: bytes) -> None:
    stride = width * 4
    raw = bytearray()
    for row in range(height):
        raw.append(0)  # filter type: None
        raw += pixels[row * stride : (row + 1) * stride]

    def chunk(kind: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(PNG_SIGNATURE)
        handle.write(chunk(b"IHDR", ihdr))
        handle.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        handle.write(chunk(b"IEND", b""))


# ── transforms ──────────────────────────────────────────────────────────────


def composite(
    pixels: bytes, count: int, background: tuple[int, int, int]
) -> bytearray:
    """Flatten straight-alpha RGBA onto an opaque background."""
    out = bytearray(count * 4)
    br, bg, bb = background
    for i in range(count):
        base = i * 4
        alpha = pixels[base + 3]
        if alpha == 255:
            out[base : base + 4] = pixels[base : base + 3] + bytes([255])
            continue
        inverse = 255 - alpha
        out[base] = (pixels[base] * alpha + br * inverse) // 255
        out[base + 1] = (pixels[base + 1] * alpha + bg * inverse) // 255
        out[base + 2] = (pixels[base + 2] * alpha + bb * inverse) // 255
        out[base + 3] = 255
    return out


def monochrome(pixels: bytes, count: int) -> bytearray:
    """White-on-transparent silhouette for Android's themed icon.

    The launcher tints this with the user's theme colour and keeps the alpha,
    so only the shape survives. A plain silhouette of this duck is an
    unreadable blob, so the dark features — pupils, brows, open mouth — are
    punched back out as holes; tinted, that reads as a duck face again.

    Alpha is also hardened, because a soft 3D render's semi-transparent edge
    pixels turn into a blurry halo once flattened to a single colour.
    """
    out = bytearray(count * 4)
    for i in range(count):
        base = i * 4
        alpha = pixels[base + 3]
        hard = 0 if alpha < 24 else 255 if alpha > 160 else (alpha - 24) * 255 // 136

        if hard:
            luma = (
                pixels[base] * 54 + pixels[base + 1] * 183 + pixels[base + 2] * 19
            ) >> 8
            # Below ~110 is only the eyes, eyebrows and mouth interior; the
            # yellow body sits above 160 and the orange beak around 170.
            if luma < 88:
                hard = 0
            elif luma < 120:
                hard = hard * (luma - 88) // 32

        out[base] = 255
        out[base + 1] = 255
        out[base + 2] = 255
        out[base + 3] = hard
    return out


def bounding_box(
    pixels: bytes, width: int, height: int, threshold: int = 40
) -> tuple[int, int, int, int]:
    """Tight box around everything more opaque than [threshold]."""
    min_x, min_y, max_x, max_y = width, height, -1, -1
    for y in range(height):
        row = y * width
        for x in range(width):
            if pixels[(row + x) * 4 + 3] > threshold:
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y
    if max_x < 0:
        return 0, 0, width - 1, height - 1
    return min_x, min_y, max_x, max_y


def fit_to_coverage(
    pixels: bytes,
    width: int,
    height: int,
    coverage: float,
    out_size: int | None = None,
) -> bytearray:
    """Re-centre the artwork and scale it to occupy [coverage] of the canvas.

    The source duck only fills 57% of its 1024px square, and Android's adaptive
    icon then crops to an inner safe zone — so shipped as-is it renders as a
    small duck marooned in a large dark tile. This rescales it to land on the
    safe zone properly.
    """
    canvas = out_size or min(width, height)
    min_x, min_y, max_x, max_y = bounding_box(pixels, width, height)
    src_w = max_x - min_x + 1
    src_h = max_y - min_y + 1

    scale = (coverage * canvas) / max(src_w, src_h)
    dst_w = max(1, int(src_w * scale))
    dst_h = max(1, int(src_h * scale))
    offset_x = (canvas - dst_w) // 2
    offset_y = (canvas - dst_h) // 2

    out = bytearray(canvas * canvas * 4)
    for y in range(dst_h):
        # Bilinear sample back into the source crop.
        sy = min_y + (y + 0.5) / scale - 0.5
        y0 = int(sy) if sy >= 0 else 0
        y1 = min(y0 + 1, height - 1)
        wy = sy - y0 if sy >= 0 else 0.0
        for x in range(dst_w):
            sx = min_x + (x + 0.5) / scale - 0.5
            x0 = int(sx) if sx >= 0 else 0
            x1 = min(x0 + 1, width - 1)
            wx = sx - x0 if sx >= 0 else 0.0

            base_dst = ((y + offset_y) * canvas + (x + offset_x)) * 4
            for channel in range(4):
                p00 = pixels[(y0 * width + x0) * 4 + channel]
                p01 = pixels[(y0 * width + x1) * 4 + channel]
                p10 = pixels[(y1 * width + x0) * 4 + channel]
                p11 = pixels[(y1 * width + x1) * 4 + channel]
                top = p00 + (p01 - p00) * wx
                bottom = p10 + (p11 - p10) * wx
                out[base_dst + channel] = int(top + (bottom - top) * wy)
    return out


def tinted(pixels: bytes, count: int) -> bytearray:
    """Luminance-only version, for iOS's tinted (monochrome) appearance."""
    out = bytearray(count * 4)
    for i in range(count):
        base = i * 4
        # Rec. 709 luma; the duck is mostly yellow, which a naive average makes
        # far too dark.
        luma = (
            pixels[base] * 54 + pixels[base + 1] * 183 + pixels[base + 2] * 19
        ) >> 8
        luma = min(255, luma)
        out[base] = out[base + 1] = out[base + 2] = luma
        out[base + 3] = pixels[base + 3]
    return out


# ── entry point ─────────────────────────────────────────────────────────────


def main() -> int:
    if not os.path.exists(SOURCE):
        print(f"error: source artwork missing: {SOURCE}", file=sys.stderr)
        return 1

    width, height, pixels = read_png_rgba(SOURCE)
    count = width * height
    print(f"source: {os.path.relpath(SOURCE, ROOT)} ({width}x{height})")

    # Legacy square / iOS icons are barely cropped, so the duck can sit large.
    framed = fit_to_coverage(pixels, width, height, 0.78)

    # Adaptive + themed layers. The generated ic_launcher.xml wraps both in
    # `<inset android:inset="16%">`, so this drawable only ever occupies 68% of
    # the 108dp layer — i.e. 73.4dp. Android's safe zone (the part no launcher
    # mask can clip) is the middle 66dp, so the duck has to fill 66/73.4 = 0.90
    # of *this* image to land exactly on it. Drawing it smaller here is what
    # left the old icon as a tiny duck marooned in a large dark tile.
    safe = fit_to_coverage(pixels, width, height, 0.90)

    outputs = {
        "icon_composed_dark.png": composite(framed, count, DARK_BG),
        "icon_composed_light.png": composite(framed, count, LIGHT_BG),
        "icon_adaptive_foreground.png": safe,
        "icon_monochrome.png": monochrome(safe, count),
        "icon_tinted.png": tinted(framed, count),
    }

    for name, data in outputs.items():
        path = os.path.join(BRANDING, name)
        write_png_rgba(path, width, height, bytes(data))
        size_kb = os.path.getsize(path) / 1024
        print(f"  wrote {name}  ({size_kb:.0f} KB)")

    write_notification_icons(pixels, width, height)

    print("\nnow run:  dart run flutter_launcher_icons")
    return 0


# Android status-bar icon sizes: 24dp at each density bucket.
NOTIFICATION_DENSITIES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}


def write_notification_icons(pixels: bytes, width: int, height: int) -> None:
    """Emit the status-bar notification icon at every density.

    Android tints notification small icons white and keeps only their alpha, so
    a full-colour launcher icon (which is what was configured) renders as an
    unreadable white blob in the status bar. The silhouette is the correct
    source, and the duck's punched-out eyes and mouth survive far enough down
    to stay recognisable.
    """
    res_root = os.path.join(ROOT, "android", "app", "src", "main", "res")
    if not os.path.isdir(res_root):
        print("  skipped notification icons (no android/ res directory)")
        return

    print("notification icons:")
    for folder, size in NOTIFICATION_DENSITIES.items():
        # Full bleed: the system already pads the icon inside the status bar.
        scaled = fit_to_coverage(pixels, width, height, 1.0, out_size=size)
        silhouette = monochrome(scaled, size * size)
        directory = os.path.join(res_root, folder)
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "ic_notification.png")
        write_png_rgba(path, size, size, bytes(silhouette))
        print(f"  wrote {folder}/ic_notification.png  ({size}x{size})")


if __name__ == "__main__":
    raise SystemExit(main())
