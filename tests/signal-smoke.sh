#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
name="nginx-signal-${RANDOM}"
tmp="$(mktemp -d)"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/mkcert" "$tmp/rootca" "$tmp/conf.d"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=localhost' \
  -keyout "$tmp/mkcert/lds-server-key.pem" \
  -out "$tmp/mkcert/lds-server.pem" >/dev/null 2>&1
cp "$tmp/mkcert/lds-server.pem" "$tmp/rootca/rootCA.pem"

docker run -d \
  --name "$name" \
  -e AUTO_RESTORE_INTERVAL_SECONDS=1 \
  -v "$tmp/conf.d:/etc/nginx/conf.d" \
  -v "$tmp/mkcert:/etc/mkcert:ro" \
  -v "$tmp/rootca:/etc/share/rootCA:ro" \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = healthy ]; then
    break
  fi
  sleep 1
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" = healthy ]

docker kill --signal=TERM "$name" >/dev/null
for _ in $(seq 1 20); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" = false ]; then
    break
  fi
  sleep 0.25
done
[ "$(docker inspect -f '{{.State.Running}}' "$name")" = false ]
exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
[ "$exit_code" -eq 0 ]

printf 'SIGTERM shutdown smoke passed.\n'
