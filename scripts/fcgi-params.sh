#!/usr/bin/env bash
set -euo pipefail

FASTCGI_PARAMS_FILE="/etc/nginx/fastcgi_params"

[[ -f "$FASTCGI_PARAMS_FILE" ]] || { echo "Error: $FASTCGI_PARAMS_FILE not found" >&2; exit 1; }

# Keep first backup only (so repeated runs don't destroy the original backup)
[[ -f "${FASTCGI_PARAMS_FILE}.bak" ]] || cp -a -- "$FASTCGI_PARAMS_FILE" "${FASTCGI_PARAMS_FILE}.bak"

# Ensure file ends with newline before appending (avoids glued lines)
tail -c 1 "$FASTCGI_PARAMS_FILE" | read -r _ || echo >>"$FASTCGI_PARAMS_FILE"

PARAMS=(
    # Forwarded headers (available as $_SERVER['HTTP_X_*'] in PHP)
    'HTTP_X_REAL_IP|$remote_addr'
    'HTTP_X_FORWARDED_FOR|$proxy_add_x_forwarded_for'
    'HTTP_X_FORWARDED_PROTO|$scheme'
    'HTTP_X_FORWARDED_HOST|$host'
    'HTTP_X_FORWARDED_PORT|$server_port'
    'HTTP_X_REQUEST_ID|$request_id'

    # Canonical params many frameworks/tools rely on
    'REMOTE_ADDR|$remote_addr'
    'REQUEST_SCHEME|$scheme'
    'SERVER_PORT|$server_port'
    'HTTP_HOST|$host'
)

has_param() {
    local key="$1"
    # match: fastcgi_param <key> ...
    grep -qE "^[[:space:]]*fastcgi_param[[:space:]]+${key}([[:space:]]+|;)" "$FASTCGI_PARAMS_FILE"
}

add_param() {
    local key="$1" val="$2"
    if has_param "$key"; then
        return 0
    fi
    printf 'fastcgi_param %s %s;\n' "$key" "$val" >>"$FASTCGI_PARAMS_FILE"
}

for pair in "${PARAMS[@]}"; do
    IFS='|' read -r key val <<<"$pair"
    add_param "$key" "$val"
done

echo "✅ FastCGI parameters updated: $FASTCGI_PARAMS_FILE"
rm -f -- "$0"
