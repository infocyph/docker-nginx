#!/bin/sh
set -eu

if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
  printf '%s\n' "$TZ" > /etc/timezone
fi

CONF_DIR="/etc/nginx/conf.d"
STATE_FILE="/tmp/nginx-disabled-state.tsv"
PREEXISTING_FILE="/tmp/nginx-preexisting-disabled.$$"
AUTO_DISABLE_INVALID_CONFS="${AUTO_DISABLE_INVALID_CONFS:-1}"
AUTO_RESTORE_DISABLED_CONFS="${AUTO_RESTORE_DISABLED_CONFS:-1}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

bounded_positive_int() {
  name="$1"
  value="$2"
  fallback="$3"
  maximum="$4"

  if awk -v v="$value" -v max="$maximum" 'BEGIN { exit !(v ~ /^[0-9]+$/ && (v + 0) >= 1 && (v + 0) <= max) }'; then
    printf '%s\n' "$value"
    return 0
  fi

  echo "WARN: invalid ${name}=${value}; defaulting to ${fallback}." >&2
  printf '%s\n' "$fallback"
}

MAX_DISABLE_ATTEMPTS="$(bounded_positive_int MAX_DISABLE_ATTEMPTS "${MAX_DISABLE_ATTEMPTS:-100}" 100 1000)"
AUTO_RESTORE_INTERVAL_SECONDS="$(bounded_positive_int AUTO_RESTORE_INTERVAL_SECONDS "${AUTO_RESTORE_INTERVAL_SECONDS:-5}" 5 3600)"

list_disabled_confs() {
  [ -d "$CONF_DIR" ] || return 0
  find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf.disabled*' -print | LC_ALL=C sort
}

file_hash() {
  sha256sum "$1" | awk '{print $1}'
}

active_config_fingerprint() {
  if [ ! -d "$CONF_DIR" ]; then
    printf 'missing\n'
    return 0
  fi

  find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' -print \
    | LC_ALL=C sort \
    | while IFS= read -r file; do
        [ -n "$file" ] || continue
        sha256sum "$file"
      done \
    | sha256sum \
    | awk '{print $1}'
}

state_get() {
  file="$1"
  [ -f "$STATE_FILE" ] || return 0
  awk -F '\t' -v path="$file" '$2 == path { print $1; exit }' "$STATE_FILE"
}

state_set() {
  file="$1"
  hash="$2"
  tmp="${STATE_FILE}.tmp.$$"

  if [ -f "$STATE_FILE" ]; then
    awk -F '\t' -v path="$file" '$2 != path' "$STATE_FILE" >"$tmp"
  else
    : >"$tmp"
  fi
  printf '%s\t%s\n' "$hash" "$file" >>"$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

state_remove() {
  file="$1"
  [ -f "$STATE_FILE" ] || return 0
  tmp="${STATE_FILE}.tmp.$$"
  awk -F '\t' -v path="$file" '$2 != path' "$STATE_FILE" >"$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

initialize_disabled_state() {
  : >"$STATE_FILE"
  list_file="/tmp/nginx-disabled-list.$$"
  list_disabled_confs >"$list_file"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    state_set "$file" "$(file_hash "$file")"
  done <"$list_file"
  rm -f "$list_file"
}

original_target_for_disabled() {
  file="$1"
  case "$file" in
    *.conf.disabled) printf '%s\n' "${file%.disabled}" ;;
    *.conf.disabled.*) printf '%s\n' "${file%%.disabled.*}" ;;
    *) return 1 ;;
  esac
}

extract_bad_conf() {
  printf '%s\n' "$1" \
    | sed -n 's#.* in \(/etc/nginx/conf\.d/[^:[:space:]]*\.conf\):[0-9][0-9]*#\1#p' \
    | head -n 1
}

disable_bad_conf() {
  bad_conf="$1"

  case "$bad_conf" in
    "$CONF_DIR"/*.conf) ;;
    *)
      echo "ERROR: refusing to quarantine path outside $CONF_DIR: $bad_conf" >&2
      return 1
      ;;
  esac

  target="${bad_conf}.disabled"
  idx=1
  while [ -e "$target" ]; do
    target="${bad_conf}.disabled.$idx"
    idx=$((idx + 1))
  done

  if ! mv "$bad_conf" "$target"; then
    echo "ERROR: cannot quarantine invalid Nginx conf (is the mount read-only?): $bad_conf" >&2
    return 1
  fi

  if [ -f "$STATE_FILE" ]; then
    state_set "$target" "$(file_hash "$target")"
  fi

  echo "WARN: disabled invalid Nginx conf: $bad_conf -> $target" >&2
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
      echo "ERROR: could not isolate invalid conf under $CONF_DIR; aborting." >&2
      return 1
    fi

    if ! disable_bad_conf "$bad_conf"; then
      printf '%s\n' "$output" >&2
      return 1
    fi
  done
}

try_restore_disabled() {
  file="$1"
  target="$(original_target_for_disabled "$file")" || return 1

  if [ -e "$target" ]; then
    return 2
  fi

  if ! mv "$file" "$target"; then
    echo "ERROR: cannot restore quarantined Nginx conf: $file" >&2
    return 1
  fi

  if output="$(nginx -t 2>&1)"; then
    state_remove "$file"
    echo "INFO: restored valid Nginx conf: $file -> $target" >&2
    return 0
  fi

  printf '%s\n' "$output" >&2
  if ! mv "$target" "$file"; then
    echo "ERROR: failed to return invalid Nginx conf to quarantine: $target" >&2
    return 1
  fi
  state_set "$file" "$(file_hash "$file")"
  echo "WARN: quarantined Nginx conf is still invalid: $file" >&2
  return 1
}

attempt_initial_restores() {
  [ -f "$PREEXISTING_FILE" ] || return 0

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue
    target="$(original_target_for_disabled "$file")" || continue
    [ -e "$target" ] && continue
    try_restore_disabled "$file" || true
  done <"$PREEXISTING_FILE"
}

process_disabled_changes() {
  RESTORED_ANY=0
  list_file="/tmp/nginx-disabled-watch.$$"
  list_disabled_confs >"$list_file"

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue

    hash="$(file_hash "$file")"
    previous="$(state_get "$file")"
    if [ -z "$previous" ]; then
      state_set "$file" "$hash"
      continue
    fi
    [ "$hash" != "$previous" ] || continue

    target="$(original_target_for_disabled "$file")" || {
      state_set "$file" "$hash"
      continue
    }

    if [ -e "$target" ]; then
      state_set "$file" "$hash"
      continue
    fi

    if try_restore_disabled "$file"; then
      RESTORED_ANY=1
    elif [ -f "$file" ]; then
      state_set "$file" "$(file_hash "$file")"
    fi
  done <"$list_file"

  rm -f "$list_file"
}

reload_nginx() {
  if ! nginx -t >/dev/null 2>&1; then
    echo "WARN: refused Nginx reload because config validation failed." >&2
    return 1
  fi
  if nginx -s reload >/dev/null 2>&1; then
    echo "INFO: reloaded Nginx after configuration change." >&2
    return 0
  fi
  echo "WARN: Nginx config is valid but reload failed; will retry after another change/check." >&2
  return 1
}

is_nginx_daemon_command() {
  [ "${1:-}" = "nginx" ] || return 1
  shift
  for arg in "$@"; do
    case "$arg" in
      *'daemon off;'*) return 0 ;;
    esac
  done
  return 1
}

start_config_watch_loop() {
  if ! is_true "$AUTO_DISABLE_INVALID_CONFS" || ! is_true "$AUTO_RESTORE_DISABLED_CONFS"; then
    return 0
  fi

  parent_pid="$$"
  initial_fingerprint="$(active_config_fingerprint)"
  (
    WATCH_ACTIVE_FINGERPRINT="$initial_fingerprint"
    while kill -0 "$parent_pid" >/dev/null 2>&1; do
      sleep "$AUTO_RESTORE_INTERVAL_SECONDS"
      kill -0 "$parent_pid" >/dev/null 2>&1 || break

      current_fingerprint="$(active_config_fingerprint)"
      if [ "$current_fingerprint" != "$WATCH_ACTIVE_FINGERPRINT" ]; then
        echo "INFO: detected active Nginx configuration change; validating." >&2
        if validate_nginx_config; then
          current_fingerprint="$(active_config_fingerprint)"
          if reload_nginx; then
            WATCH_ACTIVE_FINGERPRINT="$current_fingerprint"
          fi
        else
          echo "WARN: active Nginx configuration change could not be made valid." >&2
        fi
      fi

      process_disabled_changes
      if [ "$RESTORED_ANY" -eq 1 ]; then
        if reload_nginx; then
          WATCH_ACTIVE_FINGERPRINT="$(active_config_fingerprint)"
        fi
      fi
    done
  ) &

  echo "INFO: started change-aware Nginx config watcher (interval: ${AUTO_RESTORE_INTERVAL_SECONDS}s)." >&2
}

[ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
list_disabled_confs >"$PREEXISTING_FILE"

render-locals
if ! validate_nginx_config; then
  rm -f "$PREEXISTING_FILE"
  exit 1
fi

if is_true "$AUTO_DISABLE_INVALID_CONFS" && is_true "$AUTO_RESTORE_DISABLED_CONFS"; then
  attempt_initial_restores
fi
rm -f "$PREEXISTING_FILE"
initialize_disabled_state

if is_nginx_daemon_command "$@"; then
  start_config_watch_loop
fi

exec "$@"
