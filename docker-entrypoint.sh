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
      "allowInsecureAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
EOF
  echo "Config created. Set OPENAI_API_KEY env var for LLM access."
fi

# Ensure host-header origin fallback is always set (required for non-loopback)
if command -v node >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE','utf8'));
    if (!cfg.gateway) cfg.gateway = {};
    if (!cfg.gateway.controlUi) cfg.gateway.controlUi = {};
    if (!cfg.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback) {
      cfg.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;
      fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
      console.log('Patched config: enabled dangerouslyAllowHostHeaderOriginFallback');
    }
  " 2>/dev/null || true
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

exec node openclaw.mjs gateway --allow-unconfigured --port "${PORT:-10000}" --bind "$BIND_MODE"
