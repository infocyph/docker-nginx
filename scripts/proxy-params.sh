#!/usr/bin/env bash
set -euo pipefail

PROXY_PARAMS_FILE="/etc/nginx/proxy_params"
PROXY_WEBSOCKET_FILE="/etc/nginx/proxy_websocket"
PROXY_STREAMING_FILE="/etc/nginx/proxy_streaming"

backup_if_exists() {
  local f="$1"
  [[ -f "$f" ]] && cp -f "$f" "${f}.bak"
}

write_file() {
  local f="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  install -m 0644 "$tmp" "$f"
  rm -f "$tmp"
}

backup_if_exists "$PROXY_PARAMS_FILE"
backup_if_exists "$PROXY_WEBSOCKET_FILE"
backup_if_exists "$PROXY_STREAMING_FILE"

# 1) Base proxy headers (NO websocket / NO streaming here)
write_file "$PROXY_PARAMS_FILE" <<'EOF'
# =============================================================================
# Reverse-proxy headers (safe + useful defaults)
# =============================================================================

# Canonical identity / scheme
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port $server_port;

# Canonical client IP chain
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

# Request correlation (good for logs/tracing)
proxy_set_header X-Request-ID $request_id;

# Timeouts (dev-friendly)
proxy_read_timeout 600s;
proxy_send_timeout 600s;

# Optional vendor headers
proxy_set_header CF-Connecting-IP $http_cf_connecting_ip;
proxy_set_header True-Client-IP $http_true_client_ip;
proxy_set_header Fastly-Client-IP $http_fastly_client_ip;
EOF

# 2) WebSockets / HMR (opt-in per vhost/location)
write_file "$PROXY_WEBSOCKET_FILE" <<'EOF'
# =============================================================================
# WebSockets / HMR (Node, Vite, Next dev, Socket.IO) — include per-location
# =============================================================================
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
EOF

# 3) Streaming / SSE / long responses (opt-in per vhost/location)
write_file "$PROXY_STREAMING_FILE" <<'EOF'
# =============================================================================
# Streaming / SSE / long-poll — include per-location
# =============================================================================
proxy_buffering off;
proxy_request_buffering off;
EOF

echo "✅ Proxy files written:"
echo "  - $PROXY_PARAMS_FILE"
echo "  - $PROXY_WEBSOCKET_FILE"
echo "  - $PROXY_STREAMING_FILE"
