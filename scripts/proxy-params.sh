#!/usr/bin/env bash
set -euo pipefail

# Replace the original /etc/nginx/proxy_params and create companion includes:
# - proxy_params_ws        : only where WS/HMR is needed
# - proxy_params_streaming : only where SSE/streaming/long-poll benefits from no buffering

PROXY_PARAMS_FILE="/etc/nginx/proxy_params"
PROXY_WS_FILE="/etc/nginx/proxy_params_ws"
PROXY_STREAMING_FILE="/etc/nginx/proxy_params_streaming"

backup_if_exists() {
  local f="$1"
  [[ -f "$f" ]] && cp -a -- "$f" "${f}.bak"
}

backup_if_exists "$PROXY_PARAMS_FILE"
backup_if_exists "$PROXY_WS_FILE"
backup_if_exists "$PROXY_STREAMING_FILE"

# Base proxy params (safe for ALL locations)
cat <<'EOF' >"$PROXY_PARAMS_FILE"
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

# WebSockets / HMR params (include ONLY where needed)
cat <<'EOF' >"$PROXY_WS_FILE"
# =============================================================================
# WebSockets / HMR — include ONLY where needed
# =============================================================================

proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
EOF

# SSE / streaming params (include ONLY where needed)
cat <<'EOF' >"$PROXY_STREAMING_FILE"
# =============================================================================
# Streaming / SSE / long-poll tuning — include ONLY where needed
# =============================================================================
# For EventSource/SSE you typically want buffering OFF and to avoid request buffering too.

proxy_buffering off;
proxy_request_buffering off;
EOF

echo "✅ Proxy include files written:"
echo "   - $PROXY_PARAMS_FILE"
echo "   - $PROXY_WS_FILE"
echo "   - $PROXY_STREAMING_FILE"
echo
echo "ℹ️ Suggested usage:"
echo "   include /etc/nginx/proxy_params;                # everywhere"
echo "   include /etc/nginx/proxy_params_ws;             # ws/hmr locations only"
echo "   include /etc/nginx/proxy_params_streaming;      # sse/streaming locations only"

rm -f -- "$0"
