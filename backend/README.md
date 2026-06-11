# Duck Downloader API

FastAPI service for extracting public media metadata and downloading public media through `yt-dlp`.

## Run

```bash
docker compose up --build
```

The API runs on `http://localhost:8000`.

## Deploy on Render Free

This repo includes a root `render.yaml` Blueprint for a free Render Web Service.
Render's free tier is best-effort: it can sleep after idle time, restart at any
time, and does not keep local files permanently.

1. Push this repository to GitHub.
2. In Render, create a new Blueprint from the repository.
3. Keep the service on the Free plan.
4. After Render creates the service, confirm the public URL. If Render changes
   the subdomain from `duck-downloader-api.onrender.com`, update
   `DUCK_PUBLIC_BASE_URL` in the Render dashboard to the real service URL.
5. Test:

```bash
curl https://duck-downloader-api.onrender.com/health
```

For the free plan, downloads are stored in `/tmp/downloads` and can disappear on
restart, redeploy, or spin-down. Keep `DUCK_MAX_CONCURRENT_DOWNLOADS` low.

Lifetime Pro license keys are read from `DUCK_PRO_LICENSE_KEYS` as a comma-separated list:

```bash
DUCK_PRO_LICENSE_KEYS=DUCK-PRO-1234,DUCK-PRO-5678
```

## Endpoints

`POST /api/extract`

```json
{"url":"https://public.example/video"}
```

`POST /api/download`

```json
{"url":"https://public.example/video","type":"video","quality":"1080"}
```

`POST /api/license/activate`

```json
{"licenseKey":"DUCK-PRO-1234"}
```

`POST /api/license/verify`

```json
{"licenseKey":"DUCK-PRO-1234"}
```

`GET /api/status/{downloadId}`

`WS /ws/download/{downloadId}`

## Safety

Duck only accepts public `http` and `https` URLs, blocks local/private hosts, sanitizes output filenames, stores files inside the configured storage directory, and delegates extraction to `yt-dlp`. It does not bypass DRM, private content, paywalls, or platform protection.
