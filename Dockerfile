FROM node:22-bookworm

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

COPY . .
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Create startup script using POSIX sh (not bash) for portability
# Uses explicit path /home/node/.openclaw to avoid $HOME build vs runtime mismatch
RUN cat > /app/docker-entrypoint.sh << 'ENTRYPOINT_EOF'
#!/bin/sh
set -e

# Use explicit path for node user, or OPENCLAW_STATE_DIR if set
STATE_DIR="${OPENCLAW_STATE_DIR:-/home/node/.openclaw}"
mkdir -p "$STATE_DIR"
CONFIG_FILE="$STATE_DIR/openclaw.json"

# Delete old config if OPENCLAW_RESET_CONFIG is set
if [ "$OPENCLAW_RESET_CONFIG" = "true" ] && [ -f "$CONFIG_FILE" ]; then
  echo "Resetting config (OPENCLAW_RESET_CONFIG=true)"
  rm -f "$CONFIG_FILE"
fi

# Create minimal config if none exists
# Note: OPENAI_API_KEY is read from env at runtime by OpenClaw, not stored in config
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Creating new config at $CONFIG_FILE"
  cat > "$CONFIG_FILE" << EOF
{
  "gateway": {
    "controlUi": {
      "allowInsecureAuth": true
    }
  }
}
EOF
  echo "Config created. Set OPENAI_API_KEY env var for LLM access."
fi

# Determine bind mode based on whether auth token is configured
# --bind lan requires OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD
BIND_MODE="loopback"
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ] || [ -n "$OPENCLAW_GATEWAY_PASSWORD" ]; then
  BIND_MODE="lan"
  echo "Auth configured, binding to LAN (0.0.0.0)"
else
  echo "No auth token set, binding to loopback only (127.0.0.1)"
  echo "Set OPENCLAW_GATEWAY_TOKEN to enable LAN binding for health checks"
fi

exec node dist/index.js gateway --allow-unconfigured --port "${PORT:-10000}" --bind "$BIND_MODE"
ENTRYPOINT_EOF
RUN chmod +x /app/docker-entrypoint.sh

# Allow non-root user to write temp files during runtime/tests.
RUN chown -R node:node /app

# Security hardening: Run as non-root user
# The node:22-bookworm image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

# Set default state dir for node user
ENV OPENCLAW_STATE_DIR=/home/node/.openclaw

CMD ["/app/docker-entrypoint.sh"]
