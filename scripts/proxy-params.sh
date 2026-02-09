#!/usr/bin/env bash
set -euo pipefail

PROXY_PARAMS_FILE="/etc/nginx/proxy_params"
PROXY_WEBSOCKET_FILE="/etc/nginx/proxy_websocket"
PROXY_STREAMING_FILE="/etc/nginx/proxy_streaming"

# One-time backups (do not overwrite on repeated runs)
[[ -f "$PROXY_PARAMS_FILE" && ! -f "${PROXY_PARAMS_FILE}.bak" ]] && cp -a -- "$PROXY_PARAMS_FILE" "${PROXY_PARAMS_FILE}.bak" || true
[[ -f "$PROXY_WEBSOCKET_FILE" && ! -f "${PROXY_WEBSOCKET_FILE}.bak" ]] && cp -a -- "$PROXY_WEBSOCKET_FILE" "${PROXY_WEBSOCKET_FILE}.bak" || true
[[ -f "$PROXY_STREAMING_FILE" && ! -f "${PROXY_STREAMING_FILE}.bak" ]] && cp -a -- "$PROXY_STREAMING_FILE" "${PROXY_STREAMING_FILE}.bak" || true

# -----------------------------------------------------------------------------
# 1) Base proxy params (SAFE for HTTP/2)
#    IMPORTANT: No Upgrade/Connection here (those are HTTP/1.1 hop-by-hop).
# -----------------------------------------------------------------------------
cat <<'EOF' >"$PROXY_PARAMS_FILE"
# =============================================================================
# Reverse-proxy headers
# =============================================================================

# Canonical identity / scheme
proxy_set_header Host              $host;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port  $server_port;

# Canonical client IP chain
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;

# Request correlation (good for logs/tracing)
proxy_set_header X-Request-ID      $request_id;

# Optional vendor headers (harmless if empty)
proxy_set_header CF-Connecting-IP  $http_cf_connecting_ip;
proxy_set_header True-Client-IP    $http_true_client_ip;
proxy_set_header Fastly-Client-IP  $http_fastly_client_ip;

# Timeouts (dev-friendly)
proxy_read_timeout 600s;
proxy_send_timeout 600s;
EOF

# -----------------------------------------------------------------------------
# 2) WebSocket/HMR snippet
# -----------------------------------------------------------------------------
cat <<'EOF' >"$PROXY_WEBSOCKET_FILE"
# =============================================================================
# WebSockets / HMR (Node, Vite, Next dev, Socket.IO)
# Include this ONLY inside WS/HMR locations.
# =============================================================================
proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection $connection_upgrade;
EOF

# -----------------------------------------------------------------------------
# 3) Streaming/SSE snippet
# -----------------------------------------------------------------------------
cat <<'EOF' >"$PROXY_STREAMING_FILE"
# =============================================================================
# Streaming/SSE helpers
# Include this ONLY inside streaming/SSE locations.
# =============================================================================
proxy_buffering off;
proxy_request_buffering off;
# Optional: for long-lived streams
proxy_cache off;
EOF

echo "✅ Wrote: $PROXY_PARAMS_FILE"
echo "✅ Wrote: $PROXY_WEBSOCKET_FILE"
echo "✅ Wrote: $PROXY_STREAMING_FILE"

rm -f -- "$0"
