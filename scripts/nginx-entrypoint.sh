#!/bin/sh
set -eu

if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
  printf '%s\n' "$TZ" > /etc/timezone
fi

/usr/local/bin/render-locals.sh

AUTO_DISABLE_INVALID_CONFS="${AUTO_DISABLE_INVALID_CONFS:-1}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_nginx_config() {
  if ! is_true "$AUTO_DISABLE_INVALID_CONFS"; then
    nginx -t
    return 0
  fi

  DISABLED_DIR="/etc/nginx/conf.d.disabled"
  mkdir -p "$DISABLED_DIR"

  ATTEMPT=0
  MAX_ATTEMPTS=100

  while :; do
    if OUTPUT="$(nginx -t 2>&1)"; then
      printf '%s\n' "$OUTPUT"
      return 0
    fi

    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
      printf '%s\n' "$OUTPUT" >&2
      echo "ERROR: too many invalid Nginx conf files to auto-disable." >&2
      return 1
    fi

    BAD_CONF="$(
      printf '%s\n' "$OUTPUT" \
      | sed -n 's#.* in \(/etc/nginx/conf\.d/[^:[:space:]]*\.conf\):[0-9][0-9]*#\1#p' \
      | head -n 1
    )"

    if [ -z "$BAD_CONF" ] || [ ! -f "$BAD_CONF" ]; then
      printf '%s\n' "$OUTPUT" >&2
      echo "ERROR: could not isolate invalid conf under /etc/nginx/conf.d; aborting." >&2
      return 1
    fi

    BASE_NAME="$(basename "$BAD_CONF")"
    TARGET="$DISABLED_DIR/$BASE_NAME.disabled"
    IDX=1
    while [ -e "$TARGET" ]; do
      TARGET="$DISABLED_DIR/$BASE_NAME.disabled.$IDX"
      IDX=$((IDX + 1))
    done

    mv "$BAD_CONF" "$TARGET"
    echo "WARN: disabled invalid Nginx conf: $BAD_CONF -> $TARGET" >&2
  done
}

validate_nginx_config

exec "$@"
