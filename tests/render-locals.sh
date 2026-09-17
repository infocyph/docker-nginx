#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
routes='valid.localhost=svc-name:8080,admin.localhost=evil:1,bad..localhost=bad:80,outside.test=bad:80,-bad.localhost=bad:80,bad-.localhost=bad:80,zero.localhost=svc:0,high.localhost=svc:65536,dup.localhost=first:1000,dup.localhost=second:2000,under.localhost=svc_name:8081'

docker run --rm \
  --entrypoint sh \
  -e LOCALHOST_ROUTES="$routes" \
  "$image" -ec '
    render-locals

    grep -Fq "  valid.localhost svc-name:8080;" /etc/nginx/locals.conf
    grep -Fq "  admin.localhost server-tools:9911;" /etc/nginx/locals.conf
    grep -Fq "  dup.localhost first:1000;" /etc/nginx/locals.conf
    grep -Fq "  under.localhost svc_name:8081;" /etc/nginx/locals.conf

    ! grep -Fq "evil:1" /etc/nginx/locals.conf
    ! grep -Fq "bad..localhost" /etc/nginx/locals.conf
    ! grep -Fq "outside.test" /etc/nginx/locals.conf
    ! grep -Fq -- "-bad.localhost" /etc/nginx/locals.conf
    ! grep -Fq "bad-.localhost" /etc/nginx/locals.conf
    ! grep -Fq "zero.localhost" /etc/nginx/locals.conf
    ! grep -Fq "high.localhost" /etc/nginx/locals.conf
    ! grep -Fq "second:2000" /etc/nginx/locals.conf

    grep -Fq "listen 80 default_server;" /etc/nginx/locals.conf
    grep -Fq "listen 443 ssl default_server;" /etc/nginx/locals.conf
    grep -Fq "proxy_set_header Host $host;" /etc/nginx/locals.conf
    grep -Fq "include /etc/nginx/proxy_timeouts;" /etc/nginx/locals.conf
    grep -Fq "location = /api/tail" /etc/nginx/locals.conf
    grep -Fq "client_max_body_size 10G;" /etc/nginx/locals.conf
    ! grep -Fq "map $http_host $log_host" /etc/nginx/locals.conf
  '

docker run --rm \
  --entrypoint sh \
  -e LOCALHOST_CLIENT_MAX_BODY_SIZE=512m \
  "$image" -ec '
    render-locals
    grep -Fq "client_max_body_size 512M;" /etc/nginx/locals.conf
  '

if docker run --rm \
  --entrypoint sh \
  -e LOCALHOST_CLIENT_MAX_BODY_SIZE=invalid \
  "$image" -ec 'render-locals' >/dev/null 2>&1; then
  echo 'Expected invalid LOCALHOST_CLIENT_MAX_BODY_SIZE to fail.' >&2
  exit 1
fi

printf 'Local convenience router contracts passed.\n'
