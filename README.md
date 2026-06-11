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

## Free External Backend on Render

This project can be deployed to Render Free using the included `render.yaml`.
This keeps the backend off your own PC, but it is not true 24/7 hosting: Render
Free can spin down after idle time and local downloaded files can be lost after
restart, redeploy, or spin-down.

Steps:

1. Push the repo to GitHub.
2. In Render, create a Blueprint from this repo.
3. Deploy the `duck-downloader-api` free web service.
4. Check the generated Render URL. If it is not
   `https://duck-downloader-api.onrender.com`, update `DUCK_PUBLIC_BASE_URL` in
   the Render service environment to the real URL.
5. Test the backend:

```powershell
curl.exe https://duck-downloader-api.onrender.com/health
```

Build the Flutter app against the Render backend:

```powershell
& 'C:\Users\me548\develop\flutter\bin\flutter.bat' build apk `
  --dart-define=DUCK_API_BASE_URL=https://duck-downloader-api.onrender.com
```

## Run App

Android emulator uses `10.0.2.2` by default:

```powershell
& 'C:\Users\me548\develop\flutter\bin\flutter.bat' run
```

Physical devices need your machine IP:

```powershell
& 'C:\Users\me548\develop\flutter\bin\flutter.bat' run `
  --dart-define=DUCK_API_BASE_URL=http://YOUR_IP:8000 `
  --dart-define=DUCK_WS_BASE_URL=ws://YOUR_IP:8000
```

## API

- `POST /api/extract`
- `POST /api/download`
- `GET /api/status/{downloadId}`
- `WS /ws/download/{downloadId}`

## Notes

Duck supports public sources supported by `yt-dlp`. It never bypasses DRM or private access controls. Audio is never auto-saved to the gallery.
