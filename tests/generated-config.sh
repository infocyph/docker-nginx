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
  locals_line="$(grep -nF "include /etc/nginx/locals.conf;" /etc/nginx/nginx.conf | cut -d: -f1)"
  conf_d_line="$(grep -nE "^[[:space:]]*include[[:space:]]+/etc/nginx/conf\\.d/\\*\\.conf;[[:space:]]*$" /etc/nginx/nginx.conf | head -n 1 | cut -d: -f1)"
  test -n "$locals_line"
  test -n "$conf_d_line"
  test "$locals_line" -lt "$conf_d_line"

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

  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_X_REAL_IP[[:space:]]+\\\$remote_addr;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_X_FORWARDED_FOR[[:space:]]+\\\$proxy_add_x_forwarded_for;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_X_FORWARDED_PROTO[[:space:]]+\\\$scheme;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_X_FORWARDED_HOST[[:space:]]+\\\$host;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_X_FORWARDED_PORT[[:space:]]+\\\$server_port;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_X_REQUEST_ID[[:space:]]+\\\$request_id;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+REMOTE_ADDR[[:space:]]+\\\$remote_addr;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+REQUEST_SCHEME[[:space:]]+\\\$scheme;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+SERVER_PORT[[:space:]]+\\\$server_port;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_HOST[[:space:]]+\\\$host;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTPS[[:space:]]+\\\$https([[:space:]]+if_not_empty)?;" /etc/nginx/fastcgi_params
  grep -Eq "^[[:space:]]*fastcgi_param[[:space:]]+HTTP_X_FORWARDED_SSL[[:space:]]+\\\$https;" /etc/nginx/fastcgi_params

  render-locals
  grep -Fq '"'"'""      "";'"'"' /etc/nginx/locals.conf
  grep -Fq "ssl_protocols TLSv1.2 TLSv1.3;" /etc/nginx/locals.conf
  grep -Fq "ssl_ciphers \"ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305\";" /etc/nginx/locals.conf
  ! grep -Fq "TLS_AES_" /etc/nginx/locals.conf
  ! grep -Fq "AES256-SHA:AES128-SHA" /etc/nginx/locals.conf
'

printf 'Generated config contracts passed.\n'
