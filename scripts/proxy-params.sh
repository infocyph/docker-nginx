#!/usr/bin/env bash
set -euo pipefail

PROXY_PARAMS_FILE="/etc/nginx/proxy_params"

# Backup existing file if it exists
[[ -f "$PROXY_PARAMS_FILE" ]] && cp "$PROXY_PARAMS_FILE" "${PROXY_PARAMS_FILE}.bak"

# Write the proxy parameters to the file (quoted heredoc prevents shell expansion)
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

# WebSockets / HMR (Node, Vite, Next dev, Socket.IO)
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_http_version 1.1;

# Timeouts (dev-friendly)
proxy_read_timeout 600s;
proxy_send_timeout 600s;

# Optional vendor headers
proxy_set_header CF-Connecting-IP $http_cf_connecting_ip;
proxy_set_header True-Client-IP $http_true_client_ip;
proxy_set_header Fastly-Client-IP $http_fastly_client_ip;

# If you do SSE/streaming responses, uncomment:
# proxy_buffering off;
EOF

echo "✅ Proxy parameters successfully written to $PROXY_PARAMS_FILE"
rm -f -- "$0"
