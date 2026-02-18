#!/usr/bin/env bash
set -euo pipefail

FASTCGI_PARAMS_FILE="/etc/nginx/fastcgi_params"
STREAMING_FILE="/etc/nginx/fastcgi_streaming"

die() { echo "Error: $*" >&2; exit 1; }

[[ -f "$FASTCGI_PARAMS_FILE" ]] || die "$FASTCGI_PARAMS_FILE not found"

# Keep first backup only (re-runs must not overwrite original backup)
[[ -f "${FASTCGI_PARAMS_FILE}.bak" ]] || cp -a -- "$FASTCGI_PARAMS_FILE" "${FASTCGI_PARAMS_FILE}.bak"

# Ensure file ends with newline (avoid glued lines on append)
ensure_newline_eof() {
    local f="$1"
    # empty file -> just add newline
    [[ -s "$f" ]] || { printf '\n' >>"$f"; return 0; }

    # Read last byte safely; if not newline, append newline
    local last
    last="$(tail -c 1 "$f" 2>/dev/null || true)"
    [[ "$last" == $'\n' ]] || printf '\n' >>"$f"
}
ensure_newline_eof "$FASTCGI_PARAMS_FILE"

# Params to add if missing
# NOTE: fastcgi_param keys are for upstream (PHP-FPM) env vars.
PARAMS=(
    # Forwarded headers (available in PHP as HTTP_X_* if you read headers)
    'HTTP_X_REAL_IP|$remote_addr'
    'HTTP_X_FORWARDED_FOR|$proxy_add_x_forwarded_for'
    'HTTP_X_FORWARDED_PROTO|$scheme'
    'HTTP_X_FORWARDED_HOST|$host'
    'HTTP_X_FORWARDED_PORT|$server_port'
    'HTTP_X_REQUEST_ID|$request_id'

    # Canonical values many apps rely on
    'REMOTE_ADDR|$remote_addr'
    'REQUEST_SCHEME|$scheme'
    'SERVER_PORT|$server_port'
    'HTTP_HOST|$host'

    # HTTPS-awareness for frameworks (Laravel/Symfony/etc.)
    # $https is "on" for TLS, empty otherwise.
    'HTTPS|$https'
    # Optional hint used by some stacks/tools
    'HTTP_X_FORWARDED_SSL|$https'
)

has_param() {
    local key="$1"
    grep -qE "^[[:space:]]*fastcgi_param[[:space:]]+${key}([[:space:]]+|;)" "$FASTCGI_PARAMS_FILE"
}

add_param() {
    local key="$1" val="$2"
    has_param "$key" && return 0
    printf 'fastcgi_param %s %s;\n' "$key" "$val" >>"$FASTCGI_PARAMS_FILE"
}

for pair in "${PARAMS[@]}"; do
    IFS='|' read -r key val <<<"$pair"
    add_param "$key" "$val"
done

# Write FastCGI streaming include (opt-in per vhost/location)
# Keep first backup only
if [[ -f "$STREAMING_FILE" ]]; then
    [[ -f "${STREAMING_FILE}.bak" ]] || cp -a -- "$STREAMING_FILE" "${STREAMING_FILE}.bak"
fi

tmp="${STREAMING_FILE}.tmp.$$"
cat >"$tmp" <<'EOF'
# =============================================================================
# FastCGI streaming / SSE / long-poll — include per-location when needed
# =============================================================================
fastcgi_buffering off;
fastcgi_request_buffering off;
EOF
chmod 0644 "$tmp" || true
mv -f "$tmp" "$STREAMING_FILE"

echo "✅ FastCGI parameters updated: $FASTCGI_PARAMS_FILE"
echo "✅ FastCGI streaming include written: $STREAMING_FILE"
rm -f -- "$0"
