#!/usr/bin/env bash
set -euo pipefail

FASTCGI_PARAMS_FILE="/etc/nginx/fastcgi_params"
STREAMING_FILE="/etc/nginx/fastcgi_streaming"

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

ensure_newline_eof() {
    local file="$1" last_byte

    [[ -s "$file" ]] || return 0
    last_byte="$(tail -c 1 "$file" | od -An -tuC | tr -d '[:space:]')"
    [[ "$last_byte" == "10" ]] || printf '\n' >>"$file"
}

has_param() {
    local key="$1"
    grep -qE "^[[:space:]]*fastcgi_param[[:space:]]+${key}([[:space:]]+|;)" "$FASTCGI_PARAMS_FILE"
}

add_param() {
    local key="$1" value="$2"
    has_param "$key" && return 0
    printf 'fastcgi_param %s %s;\n' "$key" "$value" >>"$FASTCGI_PARAMS_FILE"
}

assert_single_param() {
    local key="$1" count
    count="$(grep -Ec "^[[:space:]]*fastcgi_param[[:space:]]+${key}([[:space:]]+|;)" "$FASTCGI_PARAMS_FILE" || true)"
    [[ "$count" -eq 1 ]] || die "expected exactly one fastcgi_param for $key, found $count"
}

[[ -f "$FASTCGI_PARAMS_FILE" ]] || die "$FASTCGI_PARAMS_FILE not found"
backup_once "$FASTCGI_PARAMS_FILE"
ensure_newline_eof "$FASTCGI_PARAMS_FILE"

PARAMS=(
    'HTTP_X_REAL_IP|$remote_addr'
    'HTTP_X_FORWARDED_FOR|$proxy_add_x_forwarded_for'
    'HTTP_X_FORWARDED_PROTO|$scheme'
    'HTTP_X_FORWARDED_HOST|$host'
    'HTTP_X_FORWARDED_PORT|$server_port'
    'HTTP_X_REQUEST_ID|$request_id'
    'REMOTE_ADDR|$remote_addr'
    'REQUEST_SCHEME|$scheme'
    'SERVER_PORT|$server_port'
    'HTTP_HOST|$host'
    'HTTPS|$https'
    'HTTP_X_FORWARDED_SSL|$https'
)

for pair in "${PARAMS[@]}"; do
    IFS='|' read -r key value <<<"$pair"
    add_param "$key" "$value"
    assert_single_param "$key"
done

backup_once "$STREAMING_FILE"
tmp="${STREAMING_FILE}.tmp.$$"
trap 'rm -f -- "$tmp"' EXIT
cat >"$tmp" <<'EOF'
# =============================================================================
# FastCGI streaming / SSE / long-poll — include per-location when needed
# =============================================================================
fastcgi_buffering off;
fastcgi_request_buffering off;
EOF
chmod 0644 "$tmp"
mv -f "$tmp" "$STREAMING_FILE"
trap - EXIT

printf 'FastCGI parameters updated: %s\n' "$FASTCGI_PARAMS_FILE"
printf 'FastCGI streaming include written: %s\n' "$STREAMING_FILE"
