# ============================================================================
# Zapp Survival Arena — Dedicated Server Dockerfile for Render Web Services
# Optimized for headless Linux container deployment with WebSocket transport
# ============================================================================

FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2

ENV DEBIAN_FRONTEND=noninteractive \
    PORT=10000 \
    BIND_IP=0.0.0.0

# Install runtime dependencies required for Godot 4 headless execution
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    unzip \
    libfontconfig1 \
    libgl1 \
    libasound2 \
    && rm -rf /var/lib/apt/lists/*

# Set up Godot installation directory
WORKDIR /opt/godot

# Fetch official Godot headless Linux binary
RUN wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -O /tmp/godot.zip \
    || wget -q "https://downloads.tuxfamily.org/godotengine/${GODOT_VERSION}/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -O /tmp/godot.zip \
    && unzip -q /tmp/godot.zip -d /opt/godot \
    && rm /tmp/godot.zip \
    && mv /opt/godot/Godot_v* /opt/godot/godot \
    && chmod +x /opt/godot/godot

# Copy application files
WORKDIR /app
COPY . /app

# Ensure entrypoint script is executable
RUN chmod +x /app/entrypoint.sh

# Expose Render service port
EXPOSE 10000

ENTRYPOINT ["/app/entrypoint.sh"]
