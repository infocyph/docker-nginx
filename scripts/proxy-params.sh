#!/usr/bin/env bash
set -euo pipefail

PROXY_PARAMS_FILE="/etc/nginx/proxy_params"
PROXY_WEBSOCKET_FILE="/etc/nginx/proxy_websocket"
PROXY_STREAMING_FILE="/etc/nginx/proxy_streaming"

die() { echo "Error: $*" >&2; exit 1; }

backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ -f "${f}.bak" ]] && return 0
  cp -a -- "$f" "${f}.bak" || die "failed to backup $f"
}

write_atomic() {
  local f="$1"
  local dir tmp

  dir="$(dirname "$f")"
  mkdir -p "$dir" || die "failed to mkdir: $dir"

  # Busybox-safe temp file creation (no mktemp dependency)
  tmp="${f}.tmp.$$"
  : >"$tmp" || die "failed to create temp: $tmp"

  # shellcheck disable=SC2094
  cat >"$tmp"
  chmod 0644 "$tmp" || true
  mv -f "$tmp" "$f" || die "failed to move $tmp to $f"
}

backup_once "$PROXY_PARAMS_FILE"
backup_once "$PROXY_WEBSOCKET_FILE"
backup_once "$PROXY_STREAMING_FILE"

# 1) Base proxy headers (NO websocket / NO streaming here)
write_atomic "$PROXY_PARAMS_FILE" <<'EOF'
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

# Optional vendor headers (safe to keep even if unset)
proxy_set_header CF-Connecting-IP $http_cf_connecting_ip;
proxy_set_header True-Client-IP $http_true_client_ip;
proxy_set_header Fastly-Client-IP $http_fastly_client_ip;
EOF

# 2) WebSockets / HMR (opt-in per vhost/location)
# NOTE: requires you to define the map for $connection_upgrade somewhere globally, e.g. nginx.conf or locals.conf:
#   map $http_upgrade $connection_upgrade { default upgrade; "" close; }
write_atomic "$PROXY_WEBSOCKET_FILE" <<'EOF'
# =============================================================================
# WebSockets / HMR (Node, Vite, Next dev, Socket.IO) — include per-location
# =============================================================================
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
EOF

# 3) Streaming / SSE / long responses (opt-in per vhost/location)
write_atomic "$PROXY_STREAMING_FILE" <<'EOF'
# =============================================================================
# Streaming / SSE / long-poll — include per-location
# =============================================================================
proxy_buffering off;
proxy_request_buffering off;

# Avoid temp-file spooling for large upstream responses:
proxy_max_temp_file_size 0;
EOF

echo "✅ Proxy files written:"
echo "  - $PROXY_PARAMS_FILE"
echo "  - $PROXY_WEBSOCKET_FILE"
echo "  - $PROXY_STREAMING_FILE"
