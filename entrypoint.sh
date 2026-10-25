#!/bin/bash
set -e

# Render and cloud hosting platforms provide the listening port in $PORT
PORT="${PORT:-10000}"
BIND="${BIND_IP:-0.0.0.0}"

echo "============================================================"
echo " Starting Zapp Dedicated WebSocket Server"
echo " Port: ${PORT} | Bind: ${BIND}"
echo "============================================================"

exec /opt/godot/godot --headless --path /app -- --server --port="${PORT}" --bind="${BIND}"
