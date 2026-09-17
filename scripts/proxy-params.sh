#!/usr/bin/env bash
set -euo pipefail

PROXY_PARAMS_FILE="/etc/nginx/proxy_params"
PROXY_FIXEDIP_HEADERS_FILE="/etc/nginx/proxy_fixedip_headers"
PROXY_TIMEOUTS_FILE="/etc/nginx/proxy_timeouts"
PROXY_BUFFERS_FILE="/etc/nginx/proxy_buffers"
PROXY_WEBSOCKET_FILE="/etc/nginx/proxy_websocket"
PROXY_STREAMING_FILE="/etc/nginx/proxy_streaming"
PROXY_CSP_RELAX_FILE="/etc/nginx/proxy_csp_relax"
PROXY_H2_SANITIZE_FILE="/etc/nginx/proxy_h2_sanitize"

die() {
    echo "Error: $*" >&2
    exit 1
}

backup_once() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    [[ -f "${file}.bak" ]] && return 0
    cp -a -- "$file" "${file}.bak" || die "failed to backup $file"
}

write_atomic() {
    local file="$1" dir tmp

    dir="$(dirname "$file")"
    mkdir -p "$dir" || die "failed to create directory: $dir"
    tmp="${file}.tmp.$$"
    : >"$tmp" || die "failed to create temp file: $tmp"
    cat >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file" || die "failed to replace $file"
}

backup_once "$PROXY_PARAMS_FILE"
backup_once "$PROXY_FIXEDIP_HEADERS_FILE"
backup_once "$PROXY_TIMEOUTS_FILE"
backup_once "$PROXY_BUFFERS_FILE"
backup_once "$PROXY_WEBSOCKET_FILE"
backup_once "$PROXY_STREAMING_FILE"
backup_once "$PROXY_CSP_RELAX_FILE"
backup_once "$PROXY_H2_SANITIZE_FILE"

write_atomic "$PROXY_PARAMS_FILE" <<'EOF'
# =============================================================================
# Reverse-proxy headers
# =============================================================================
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port  $server_port;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Request-ID      $request_id;
EOF

write_atomic "$PROXY_FIXEDIP_HEADERS_FILE" <<'EOF'
# =============================================================================
# Fixed-IP proxy helpers (anti-CSRF/origin checks for local admin/router proxies)
# Requires $proxy_up_host and $proxy_up_proto to be set by the vhost.
# =============================================================================
proxy_set_header X-Forwarded-Host  $proxy_up_host;
proxy_set_header X-Forwarded-Proto $proxy_up_proto;
proxy_set_header X-Forwarded-Port  $server_port;
proxy_set_header Origin            $proxy_up_proto://$proxy_up_host;
proxy_set_header Referer           $proxy_up_proto://$proxy_up_host$request_uri;
EOF

write_atomic "$PROXY_TIMEOUTS_FILE" <<'EOF'
# =============================================================================
# Reverse-proxy timeouts (development-friendly)
# =============================================================================
proxy_connect_timeout 10s;
proxy_send_timeout    600s;
proxy_read_timeout    600s;
EOF

write_atomic "$PROXY_BUFFERS_FILE" <<'EOF'
# =============================================================================
# Reverse-proxy buffers
# =============================================================================
proxy_buffering on;
proxy_buffer_size 16k;
proxy_buffers 8 32k;
proxy_busy_buffers_size 64k;
EOF

write_atomic "$PROXY_WEBSOCKET_FILE" <<'EOF'
# =============================================================================
# WebSocket / HMR support — include per-location
# $connection_upgrade is defined in /etc/nginx/locals.conf.
# =============================================================================
proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection $connection_upgrade;
EOF

write_atomic "$PROXY_STREAMING_FILE" <<'EOF'
# =============================================================================
# Streaming / SSE / long-poll — include per-location
# =============================================================================
proxy_buffering off;
proxy_request_buffering off;
proxy_max_temp_file_size 0;
EOF

write_atomic "$PROXY_CSP_RELAX_FILE" <<'EOF'
# =============================================================================
# Relax Content-Security-Policy — LOCAL DEVELOPMENT ONLY
# =============================================================================
proxy_hide_header Content-Security-Policy;
add_header Content-Security-Policy "default-src * 'unsafe-inline' 'unsafe-eval' data: blob:; img-src * data: blob:; connect-src *; frame-src *;" always;
EOF

write_atomic "$PROXY_H2_SANITIZE_FILE" <<'EOF'
# =============================================================================
# Strip hop-by-hop headers that must not reach HTTP/2 clients
# =============================================================================
proxy_set_header Connection "";
proxy_set_header Upgrade "";
proxy_hide_header Connection;
proxy_hide_header Upgrade;
proxy_hide_header Keep-Alive;
proxy_hide_header Transfer-Encoding;
proxy_hide_header HTTP2-Settings;
proxy_hide_header Alt-Svc;
EOF

printf 'Proxy files written:\n'
printf '  - %s\n' \
    "$PROXY_PARAMS_FILE" \
    "$PROXY_FIXEDIP_HEADERS_FILE" \
    "$PROXY_TIMEOUTS_FILE" \
    "$PROXY_BUFFERS_FILE" \
    "$PROXY_WEBSOCKET_FILE" \
    "$PROXY_STREAMING_FILE" \
    "$PROXY_CSP_RELAX_FILE" \
    "$PROXY_H2_SANITIZE_FILE"
