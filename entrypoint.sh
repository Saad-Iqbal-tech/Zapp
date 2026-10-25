#!/bin/bash
set -e

# Render and cloud hosting platforms provide the listening port in $PORT
PORT="${PORT:-10000}"
BIND="${BIND_IP:-0.0.0.0}"

echo "============================================================"
echo " Starting Zapp Dedicated WebSocket Server"
echo " Port: ${PORT} | Bind: ${BIND}"
echo "============================================================"

# Ensure global script class cache exists so Godot runtime resolves all class_name declarations
if [ ! -f "/app/.godot/global_script_class_cache.cfg" ]; then
    echo "Generating Godot global script class cache..."
    /opt/godot/godot --headless --editor --quit --path /app || true
fi

# Run the lightweight headless dedicated server entry point
exec /opt/godot/godot --headless --path /app -s res://scripts/network/dedicated_server_runner.gd -- --port="${PORT}" --bind="${BIND}"
