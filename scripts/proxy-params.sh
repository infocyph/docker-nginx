#!/usr/bin/env bash
set -euo pipefail

PROXY_PARAMS_FILE="/etc/nginx/proxy_params"
PROXY_FIXEDIP_HEADERS_FILE="/etc/nginx/proxy_fixedip_headers"
PROXY_TIMEOUTS_FILE="/etc/nginx/proxy_timeouts"
PROXY_BUFFERS_FILE="/etc/nginx/proxy_buffers"
PROXY_WEBSOCKET_FILE="/etc/nginx/proxy_websocket"
PROXY_STREAMING_FILE="/etc/nginx/proxy_streaming"
PROXY_CSP_RELAX_FILE="/etc/nginx/proxy_csp_relax"

die() { echo "Error: $*" >&2; exit 1; }

backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ -f "${f}.bak" ]] && return 0
  cp -a -- "$f" "${f}.bak" || die "failed to backup $f"
}

write_atomic() {
  local f="$1" dir tmp

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
backup_once "$PROXY_FIXEDIP_HEADERS_FILE"
backup_once "$PROXY_TIMEOUTS_FILE"
backup_once "$PROXY_BUFFERS_FILE"
backup_once "$PROXY_WEBSOCKET_FILE"
backup_once "$PROXY_STREAMING_FILE"
backup_once "$PROXY_CSP_RELAX_FILE"

# 1) Base proxy headers
write_atomic "$PROXY_PARAMS_FILE" <<'EOP'
# =============================================================================
# Reverse-proxy headers (safe + useful defaults)
# =============================================================================

# Canonical identity / scheme
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port  $server_port;

# Canonical client IP chain
proxy_set_header X-Real-IP       $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

# Request correlation (good for logs/tracing)
proxy_set_header X-Request-ID $request_id;

# Optional vendor headers (safe to keep even if unset)
proxy_set_header CF-Connecting-IP  $http_cf_connecting_ip;
proxy_set_header True-Client-IP    $http_true_client_ip;
proxy_set_header Fastly-Client-IP  $http_fastly_client_ip;
EOP

# 1b) Fixed-IP proxy helper headers
#
# Requirements in the vhost before including this file:
#   set $proxy_up_host  <upstream host>;     # e.g. report.example.com
#   set $proxy_up_proto <http|https>;        # e.g. https
write_atomic "$PROXY_FIXEDIP_HEADERS_FILE" <<'EOP'
# =============================================================================
# Fixed-IP proxy helpers (anti-CSRF/origin checks for admin panels/routers)
# =============================================================================

# Make upstream believe client accessed the upstream hostname (not local domain)
proxy_set_header X-Forwarded-Host  $proxy_up_host;
proxy_set_header X-Forwarded-Proto $proxy_up_proto;
proxy_set_header X-Forwarded-Port  $server_port;

# Many admin panels/routers validate Origin/Referer for login POSTs
proxy_set_header Origin  $proxy_up_proto://$proxy_up_host;
proxy_set_header Referer $proxy_up_proto://$proxy_up_host$request_uri;
EOP

# 2) Timeouts (keep separate so you can override per-vhost if needed)
write_atomic "$PROXY_TIMEOUTS_FILE" <<'EOP'
# =============================================================================
# Reverse-proxy timeouts (dev-friendly)
# =============================================================================
proxy_connect_timeout 10s;
proxy_send_timeout    600s;
proxy_read_timeout    600s;
EOP

# 3) Buffers (prevents "upstream sent too big header" on login-heavy apps)
write_atomic "$PROXY_BUFFERS_FILE" <<'EOP'
# =============================================================================
# Reverse-proxy buffers
# =============================================================================
proxy_buffering on;

proxy_buffer_size 16k;
proxy_buffers 8 32k;
proxy_busy_buffers_size 64k;
EOP

# 4) WebSockets / HMR (opt-in per vhost/location)
write_atomic "$PROXY_WEBSOCKET_FILE" <<'EOP'
# =============================================================================
# WebSockets / HMR (Node, Vite, Next dev, Socket.IO) — include per-location
# =============================================================================
proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection $connection_upgrade;
EOP

# 5) Streaming / SSE / long responses (opt-in per vhost/location)
write_atomic "$PROXY_STREAMING_FILE" <<'EOP'
# =============================================================================
# Streaming / SSE / long-poll — include per-location
# =============================================================================
proxy_buffering off;
proxy_request_buffering off;
proxy_max_temp_file_size 0;
EOP

# 6) CSP relax (LAST RESORT) — include per-location
write_atomic "$PROXY_CSP_RELAX_FILE" <<'EOP'
# =============================================================================
# Relax Content-Security-Policy (use only for LOCAL DEV)
# =============================================================================
proxy_hide_header Content-Security-Policy;
add_header Content-Security-Policy "default-src * 'unsafe-inline' 'unsafe-eval' data: blob:; img-src * data: blob:; connect-src *; frame-src *;" always;
EOP

echo "✅ Proxy files written:"
echo "  - $PROXY_PARAMS_FILE"
echo "  - $PROXY_FIXEDIP_HEADERS_FILE"
echo "  - $PROXY_TIMEOUTS_FILE"
echo "  - $PROXY_BUFFERS_FILE"
echo "  - $PROXY_WEBSOCKET_FILE"
echo "  - $PROXY_STREAMING_FILE"
echo "  - $PROXY_CSP_RELAX_FILE"
