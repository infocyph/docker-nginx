#!/bin/sh
set -eu

if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
  printf '%s\n' "$TZ" > /etc/timezone
fi

CONF_DIR="/etc/nginx/conf.d"
AUTO_DISABLE_INVALID_CONFS="${AUTO_DISABLE_INVALID_CONFS:-1}"
MAX_DISABLE_ATTEMPTS="${MAX_DISABLE_ATTEMPTS:-100}"
AUTO_RESTORE_DISABLED_CONFS="${AUTO_RESTORE_DISABLED_CONFS:-1}"
AUTO_RESTORE_INTERVAL_SECONDS="${AUTO_RESTORE_INTERVAL_SECONDS:-5}"

is_true() {
  case "${1:-}" in
  1|true|TRUE|yes|YES|on|ON) return 0 ;;
  *) return 1 ;;
  esac
}

list_disabled_confs() {
  [ -d "$CONF_DIR" ] || return 0
  find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf.disabled*'
}

restore_disabled_confs() {
  [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"

  list_disabled_confs | while IFS= read -r file; do
    [ -n "$file" ] || continue

    base="$(basename "$file")"

    case "$base" in
    *.conf.disabled) restored="${base%.disabled}" ;;
    *.conf.disabled.*) restored="${base%.disabled.*}" ;;
    *) continue ;;
    esac

    target="$CONF_DIR/$restored"

    if [ -e "$target" ]; then
      echo "WARN: skipped restore because target exists: $target" >&2
      continue
    fi

    mv "$file" "$target"
    echo "INFO: restored Nginx conf: $file -> $target" >&2
  done
}

extract_bad_conf() {
  printf '%s\n' "$1" \
    | sed -n 's#.* in \(/etc/nginx/conf\.d/[^:[:space:]]*\.conf\):[0-9][0-9]*#\1#p' \
    | head -n 1
}

disable_bad_conf() {
  bad_conf="$1"
  target="${bad_conf}.disabled"
  idx=1

  while [ -e "$target" ]; do
    target="${bad_conf}.disabled.$idx"
    idx=$((idx + 1))
  done

  mv "$bad_conf" "$target"
  echo "WARN: disabled invalid Nginx conf: $bad_conf -> $target" >&2
}

count_disabled_confs() {
  list_disabled_confs | wc -l | awk '{print $1}'
}

validate_nginx_config() {
  if ! is_true "$AUTO_DISABLE_INVALID_CONFS"; then
    nginx -t
    return 0
  fi

  attempt=0

  while :; do
    if output="$(nginx -t 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$MAX_DISABLE_ATTEMPTS" ]; then
      printf '%s\n' "$output" >&2
      echo "ERROR: too many invalid Nginx conf files to auto-disable." >&2
      return 1
    fi

    bad_conf="$(extract_bad_conf "$output")"

    if [ -z "$bad_conf" ] || [ ! -f "$bad_conf" ]; then
      printf '%s\n' "$output" >&2
      echo "ERROR: could not isolate invalid conf under /etc/nginx/conf.d; aborting." >&2
      return 1
    fi

    disable_bad_conf "$bad_conf"
  done
}

start_auto_restore_loop() {
  if ! is_true "$AUTO_DISABLE_INVALID_CONFS" || ! is_true "$AUTO_RESTORE_DISABLED_CONFS"; then
    return 0
  fi

  interval="$AUTO_RESTORE_INTERVAL_SECONDS"
  case "$interval" in
  ''|*[!0-9]*)
    echo "WARN: invalid AUTO_RESTORE_INTERVAL_SECONDS=$interval; defaulting to 5." >&2
    interval=5
    ;;
  esac
  if [ "$interval" -lt 1 ]; then
    interval=1
  fi

  (
    while :; do
      sleep "$interval"

      before="$(count_disabled_confs)"
      if [ "$before" -eq 0 ]; then
        continue
      fi

      restore_disabled_confs
      if ! validate_nginx_config; then
        echo "WARN: auto-restore validation failed; will retry." >&2
        continue
      fi

      after="$(count_disabled_confs)"
      if [ "$after" -lt "$before" ]; then
        if nginx -s reload >/dev/null 2>&1; then
          echo "INFO: restored disabled Nginx conf(s); reloaded Nginx." >&2
        else
          echo "WARN: restored conf(s) but failed to reload Nginx; retrying later." >&2
        fi
      fi
    done
  ) &

  echo "INFO: started Nginx disabled-conf auto-restore loop (interval: ${interval}s)." >&2
}

restore_disabled_confs
render-locals
validate_nginx_config
start_auto_restore_loop

exec "$@"
