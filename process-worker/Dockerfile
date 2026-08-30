# Base image ships the NVIDIA CUDA runtime so Demucs can run on the GPU.
# Pick the build that matches the host driver; cu121 is widely compatible.
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    DUCK_STORAGE_DIR=/data/downloads

# FFmpeg is required for audio extraction and the final re-mux. python3 comes
# via the distro; we add pip through ensurepip rather than a separate package.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        ca-certificates \
        python3 \
        python3-pip \
        python3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install the CUDA-enabled torch wheels from PyTorch's index before the rest of
# the requirements so demucs can resolve against them. The CPU build would fall
# back automatically but would be unusably slow for production traffic.
RUN pip3 install --no-cache-dir \
    torch==2.3.1 torchaudio==2.3.1 \
    --index-url https://download.pytorch.org/whl/cu121

COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

COPY app ./app

# Bake the Demucs weights into the image.
#
# get_model("htdemucs") downloads them on first use and caches them on the
# container filesystem — which is fine on a machine that stays up, and useless
# on a serverless host that starts from a clean container every time it scales
# from zero. Without this, every cold start pays for the download again, and a
# slow or rate-limited weights host turns into a failed request.
ENV TORCH_HOME=/opt/torch
RUN python3 -c "from demucs.pretrained import get_model; get_model('htdemucs')"

RUN mkdir -p /data/downloads

# Most GPU hosts hand the container a port in $PORT and ignore EXPOSE. Cloud
# Run uses 8080, RunPod and Fly let you pick — reading the variable means the
# same image runs on all of them without a rebuild.
ENV PORT=8000
EXPOSE 8000

# Single worker: Demucs is GPU-bound and we serialise requests with an asyncio
# lock anyway. Multiple uvicorn workers would each load a copy of the model.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
