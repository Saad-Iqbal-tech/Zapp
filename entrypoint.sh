#!/bin/bash
set -e

PORT="${PORT:-10000}"
INTERNAL_PORT="7777"

echo "============================================================"
echo " Starting Zapp Dedicated Server"
echo " Render Public Port: ${PORT}"
echo " Internal Godot Port: ${INTERNAL_PORT}"
echo "============================================================"

# Ensure global script class cache exists so Godot runtime resolves all class_name declarations
if [ ! -f "/app/.godot/global_script_class_cache.cfg" ]; then
    echo "Generating Godot global script class cache..."
    /opt/godot/godot --headless --editor --quit --path /app || true
fi

# Configure Nginx reverse proxy & health check endpoint for Render
cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events {
    worker_connections 1024;
}
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    server {
        listen ${PORT};

        location = /health {
            return 200 "OK\n";
        }

        location / {
            # Render health check probe (non-WebSocket HTTP requests)
            if (\$http_upgrade !~* "websocket") {
                return 200 "Zapp Dedicated Server Online\n";
            }

            # Forward WebSockets directly to Godot
            proxy_pass http://127.0.0.1:${INTERNAL_PORT};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "Upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }
    }
}
EOF

# Start Nginx in background
nginx

# Set GODOT_PORT for internal container binding
export GODOT_PORT="${INTERNAL_PORT}"

# Start Godot dedicated server on internal port 7777 (bound to 127.0.0.1)
exec /opt/godot/godot --headless --path /app -s res://scripts/network/dedicated_server_runner.gd -- --port="${INTERNAL_PORT}" --bind="127.0.0.1"
