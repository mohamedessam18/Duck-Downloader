# Duck Downloader

Copy. Detect. Download.

Duck Downloader is a Flutter mobile app with a FastAPI backend. The app detects public media links from the real clipboard, sends local notifications, extracts real metadata through the backend, downloads media with `yt-dlp` and `FFmpeg`, stores local records in Hive, and saves videos to the gallery only when enabled.

## Stack

- Flutter stable, Riverpod, GoRouter, Hive, Dio, local notifications, WorkManager, Background Fetch
- FastAPI, Docker, yt-dlp, FFmpeg

## Run Backend

```powershell
docker compose up --build
```

## Cloudflare Named Tunnel

The mobile app uses the Cloudflare-hosted API URL by default:

```text
https://api.duckdownloader.site
```

Run the backend locally, then expose it through a Cloudflare Named Tunnel:

```powershell
docker compose up --build
curl.exe http://localhost:8000/health
```

Create the tunnel and route the fixed hostname:

```powershell
cloudflared tunnel login
```

Then run the setup script. It creates the tunnel if needed, writes
`%USERPROFILE%\.cloudflared\config.yml`, creates the DNS route, and installs the
Windows service:

```powershell
.\scripts\setup-cloudflare-tunnel.ps1
```

Test the public API:

```powershell
curl.exe https://api.duckdownloader.site/health
```

Build the Flutter app against the fixed Cloudflare backend:

```powershell
& 'C:\Users\me548\develop\flutter\bin\flutter.bat' build apk `
  --dart-define=DUCK_API_BASE_URL=https://api.duckdownloader.site
```

## Run App

Android emulator uses `10.0.2.2` by default:

```powershell
& 'C:\Users\me548\develop\flutter\bin\flutter.bat' run
```

Physical devices can use the Cloudflare URL directly:

```powershell
& 'C:\Users\me548\develop\flutter\bin\flutter.bat' run `
  --dart-define=DUCK_API_BASE_URL=https://api.duckdownloader.site
```

Plain `flutter run` also uses the Cloudflare backend by default:

```text
https://api.duckdownloader.site
```

## API

- `POST /api/extract`
- `POST /api/download`
- `GET /api/status/{downloadId}`
- `WS /ws/download/{downloadId}`

## Notes

Duck supports public sources supported by `yt-dlp`. It never bypasses DRM or private access controls. Audio is never auto-saved to the gallery.
