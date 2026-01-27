#!/usr/bin/env bash
set -euo pipefail

FASTCGI_PARAMS_FILE="/etc/nginx/fastcgi_params"

[[ -f "$FASTCGI_PARAMS_FILE" ]] || {
    echo "Error: $FASTCGI_PARAMS_FILE not found"
    exit 1
}

cp -f "$FASTCGI_PARAMS_FILE" "${FASTCGI_PARAMS_FILE}.bak"

PARAMS=(
    'HTTP_X_REAL_IP|$remote_addr'
    'HTTP_X_FORWARDED_FOR|$proxy_add_x_forwarded_for'
    'HTTP_X_FORWARDED_PROTO|$scheme'
    'HTTP_X_FORWARDED_HOST|$host'
    'HTTP_X_FORWARDED_PORT|$server_port'
    'HTTP_X_REQUEST_ID|$request_id'
)

add_if_missing() {
    local key="$1" val="$2"

    # already present?
    if grep -qE "^[[:space:]]*fastcgi_param[[:space:]]+${key}[[:space:]]+" "$FASTCGI_PARAMS_FILE"; then
        return 0
    fi

    echo "Adding missing FastCGI param: $key"
    printf "fastcgi_param %s %s;\n" "$key" "$val" >>"$FASTCGI_PARAMS_FILE"
}

for pair in "${PARAMS[@]}"; do
    IFS='|' read -r key val <<<"$pair"
    add_if_missing "$key" "$val"
done

echo "✅ FastCGI parameters updated"
rm -f -- "$0"
