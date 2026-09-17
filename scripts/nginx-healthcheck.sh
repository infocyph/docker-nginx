#!/bin/sh
set -eu

pid_file="${NGINX_PID_FILE:-/var/run/nginx.pid}"

[ -r "$pid_file" ] || exit 1
pid="$(cat "$pid_file")"

case "$pid" in
  ''|*[!0-9]*) exit 1 ;;
esac

kill -0 "$pid" 2>/dev/null || exit 1
nginx -t >/dev/null 2>&1
