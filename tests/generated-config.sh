#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"

docker run --rm --entrypoint sh "$image" -ec '
  test -s /etc/nginx/fastcgi_params
  test -s /etc/nginx/fastcgi_streaming
  test -s /etc/nginx/proxy_params
  test -s /etc/nginx/proxy_timeouts
  test -s /etc/nginx/proxy_buffers
  test -s /etc/nginx/proxy_websocket
  test -s /etc/nginx/proxy_streaming
  test -s /etc/nginx/proxy_csp_relax
  test -s /etc/nginx/proxy_h2_sanitize
  test ! -e /etc/nginx/conf.d/default.conf
  test -x /usr/local/bin/nginx-healthcheck
  test ! -e /usr/local/bin/fcgi_params.sh
  test ! -e /usr/local/bin/proxy_params.sh
  count="$(grep -Fc "include /etc/nginx/locals.conf;" /etc/nginx/nginx.conf)"
  test "$count" -eq 1
  chromacat --version >/dev/null
  bash -n /usr/local/bin/show-banner

  for header in CF-Connecting-IP True-Client-IP Fastly-Client-IP; do
    ! grep -Fq "$header" /etc/nginx/proxy_params
  done

  for key in \
    HTTP_X_REAL_IP \
    HTTP_X_FORWARDED_FOR \
    HTTP_X_FORWARDED_PROTO \
    HTTP_X_FORWARDED_HOST \
    HTTP_X_FORWARDED_PORT \
    HTTP_X_REQUEST_ID \
    REMOTE_ADDR \
    REQUEST_SCHEME \
    SERVER_PORT \
    HTTP_HOST \
    HTTPS \
    HTTP_X_FORWARDED_SSL; do
    matches="$(grep -Ec "^[[:space:]]*fastcgi_param[[:space:]]+${key}([[:space:]]+|;)" /etc/nginx/fastcgi_params || true)"
    test "$matches" -eq 1
  done

  render-locals
  grep -Fq '"'"'""      "";'"'"' /etc/nginx/locals.conf
'

printf 'Generated config contracts passed.\n'
