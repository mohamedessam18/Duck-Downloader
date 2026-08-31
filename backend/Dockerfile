# Build the local PO-token provider recommended by yt-dlp for YouTube.
# It runs beside the API and is never exposed outside this container.
#
# Node 22, not 20, because this same binary is what yt-dlp uses to solve
# YouTube's JavaScript challenge, and NodeJsRuntime.MIN_SUPPORTED_VERSION is
# (22, 0, 0). On 20 the runtime is found, rejected as too old, and yt-dlp
# silently falls back to its JS-less client — which extracts fine and then
# cannot fetch the media, so every download ended in `HTTP Error 403`.
FROM node:22-bullseye-slim AS pot-provider

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch 1.3.1 \
    https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git /opt/bgutil-provider

WORKDIR /opt/bgutil-provider/server
RUN npm ci && npx tsc && npm cache clean --force


# Keep the production base image unchanged. Railway already builds this image
# successfully; Node 20 in the stage above is compatible with Debian Bullseye.
FROM python:3.12-slim-bullseye

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DUCK_STORAGE_DIR=/tmp/duck-downloads

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg curl ca-certificates unzip libstdc++6 git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=pot-provider /usr/local/bin/node /usr/local/bin/node
COPY --from=pot-provider /opt/bgutil-provider/server /opt/bgutil-provider/server

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY static ./static

RUN mkdir -p /tmp/duck-downloads && chmod 777 /tmp/duck-downloads

# Copy the startup script that ensures the PO Token provider is healthy
# before uvicorn starts, and restarts it automatically if it crashes.
COPY start.sh /start.sh
RUN chmod +x /start.sh

# The provider listens only on localhost:4416. Its yt-dlp plugin discovers it
# automatically and generates short-lived PO tokens per YouTube request.
CMD ["/start.sh"]
