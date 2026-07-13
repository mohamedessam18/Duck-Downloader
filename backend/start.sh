#!/bin/sh
set -e

echo "[Duck] Starting bgutil PO Token provider..."
node /opt/bgutil-provider/server/build/main.js &
NODE_PID=$!

# Wait up to 30 seconds for the provider to be ready on port 4416
echo "[Duck] Waiting for PO Token provider to be healthy..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:4416 > /dev/null 2>&1; then
        echo "[Duck] PO Token provider is ready (after ${i}s)"
        break
    fi
    if ! kill -0 $NODE_PID 2>/dev/null; then
        echo "[Duck] WARNING: PO Token provider process died, restarting..."
        node /opt/bgutil-provider/server/build/main.js &
        NODE_PID=$!
    fi
    sleep 1
done

# Keep provider alive: restart it in background if it dies
(while true; do
    sleep 10
    if ! kill -0 $NODE_PID 2>/dev/null; then
        echo "[Duck] PO Token provider died, restarting..."
        node /opt/bgutil-provider/server/build/main.js &
        NODE_PID=$!
    fi
done) &

echo "[Duck] Starting FastAPI server..."
exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}"
