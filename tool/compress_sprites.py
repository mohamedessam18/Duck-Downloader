"""Resize and compress duck PNG assets in-place."""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

MAX_SIZE = 512
ASSETS = Path(__file__).resolve().parents[1] / "assets" / "images"

TARGETS = [
    ASSETS / "ducks" / "frames",
    ASSETS / "ducks",
    ASSETS / "ducks" / "premium",
    ASSETS / "branding",
]


def compress_png(path: Path) -> tuple[int, int]:
    before = path.stat().st_size
    with Image.open(path) as img:
        img = img.convert("RGBA")
        img.thumbnail((MAX_SIZE, MAX_SIZE), Image.Resampling.LANCZOS)
        img.save(
            path,
            format="PNG",
            optimize=True,
            compress_level=9,
        )
    after = path.stat().st_size
    return before, after


def main() -> int:
    paths: list[Path] = []
    for target in TARGETS:
        if target.exists():
            paths.extend(sorted(target.rglob("*.png")))
    paths = sorted(set(paths))
    if not paths:
        print("No PNG files found under assets/images")
        return 1

    total_before = 0
    total_after = 0
    for path in paths:
        before, after = compress_png(path)
        total_before += before
        total_after += after
        rel = path.relative_to(ASSETS.parent)
        print(f"{rel}: {before // 1024}KB -> {after // 1024}KB")

    print(
        f"\n{len(paths)} files | "
        f"{total_before / 1024 / 1024:.1f}MB -> {total_after / 1024 / 1024:.1f}MB "
        f"({100 - total_after * 100 / total_before:.0f}% smaller)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
