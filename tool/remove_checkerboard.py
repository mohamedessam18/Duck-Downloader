"""Remove baked-in gray/white checkerboard backgrounds from duck PNGs."""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

ASSETS = Path(__file__).resolve().parents[1] / "assets" / "images"

TARGETS = [
    ASSETS / "ducks" / "frames",
    ASSETS / "ducks" / "premium",
]


def background_alpha(r: int, g: int, b: int) -> int:
    """Return 0 = fully transparent background, 255 = keep opaque."""
    max_c = max(r, g, b)
    min_c = min(r, g, b)
    chroma = max_c - min_c

    # Duck colors are yellow/gold/orange — keep anything with real chroma.
    if chroma > 28:
        return 255

    # Light checkerboard squares (white / light gray).
    if max_c >= 198:
        return 0

    # Darker checkerboard squares.
    if max_c >= 168 and chroma <= 12:
        return 0

    # Soft fringe between duck and checkerboard (anti-aliased edges).
    if max_c >= 145 and chroma <= 18:
        fade = (max_c - 145) / 53  # 0 at 145, ~1 at 198
        return max(0, min(255, int(255 * (1 - fade))))

    return 255


def process_png(path: Path) -> tuple[int, int]:
    with Image.open(path) as img:
        rgba = img.convert("RGBA")
        pixels = rgba.load()
        width, height = rgba.size
        transparent_before = 0
        transparent_after = 0

        for y in range(height):
            for x in range(width):
                r, g, b, a = pixels[x, y]
                if a < 10:
                    transparent_before += 1
                alpha = background_alpha(r, g, b)
                if alpha < 10:
                    transparent_after += 1
                pixels[x, y] = (r, g, b, min(a, alpha))

        rgba.save(path, format="PNG", optimize=True, compress_level=9)

    total = width * height
    return transparent_before, transparent_after, total


def main() -> int:
    paths: list[Path] = []
    for target in TARGETS:
        if target.exists():
            paths.extend(sorted(target.rglob("*.png")))
    paths = sorted(set(paths))

    if not paths:
        print("No PNG files found.")
        return 1

    for path in paths:
        before, after, total = process_png(path)
        rel = path.relative_to(ASSETS.parent)
        print(
            f"{rel}: transparency {before * 100 / total:.1f}% -> "
            f"{after * 100 / total:.1f}%"
        )

    print(f"\nProcessed {len(paths)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
