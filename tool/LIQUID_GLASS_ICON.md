# Duck Downloader — Liquid Glass App Icon (iOS 26+)

## What is in the repo

- `ios/Runner/AppIcon.icon/` — layered Liquid Glass icon bundle for iOS 26 / 27
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/` — legacy fallback for iOS 18 and earlier
- `assets/images/branding/logo_launcher.png` — flat master for Android launcher
- `assets/images/branding/liquid_glass_layers/` — editable PNG layers (duck + download)

When a user enables **Liquid Glass** on the home screen, iOS composites the `.icon` layers with system glass, specular highlights, blur, and appearance modes (Default, Dark, Clear, Tinted).

## Fine-tune on Mac (recommended)

`icon.json` is a starting point. For best results on iOS 26 / 27:

1. Install **Xcode 26+** and open **Icon Composer** (`Xcode > Open Developer Tool > Icon Composer`).
2. Open `ios/Runner/AppIcon.icon` (or import layers from `assets/images/branding/liquid_glass_layers/`).
3. Preview all modes: **Default**, **Dark**, **Mono > Clear**, **Mono > Tinted**.
4. Tune per group:
   - **Specular** — edge highlights that react to Liquid Glass lighting
   - **Translucency** — how much wallpaper shows through in Clear mode
   - **Shadow** — depth without baking shadows into PNGs
5. Save the `.icon` bundle back into `ios/Runner/AppIcon.icon`.
6. Build on a device/simulator running iOS 26+ and toggle home screen appearance settings.

## Layer design rules (Apple)

- Do **not** bake corner rounding, drop shadows, or heavy gloss into PNGs.
- Keep duck and download arrow on **separate transparent layers**.
- Background gradient is configured in Icon Composer / `icon.json`, not in the duck layer.

## Android

Android uses the flat composed icon via `flutter_launcher_icons` and `logo_launcher.png` — Liquid Glass is iOS-only.

```bash
dart run flutter_launcher_icons
```

## Regenerate layers (Windows)

Source images with chroma-key removal:

```powershell
py "$env:USERPROFILE\.codex\skills\.system\imagegen\scripts\remove_chroma_key.py" `
  --input path\to\layer-duck-source.png `
  --out assets\images\branding\liquid_glass_layers\layer-duck.png `
  --auto-key border --soft-matte --despill
```

Then copy into `ios/Runner/AppIcon.icon/Assets/`.
