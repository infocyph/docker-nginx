#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
name="nginx-smoke-${RANDOM}"
tmp="$(mktemp -d)"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/mkcert" "$tmp/rootca"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=localhost' \
  -keyout "$tmp/mkcert/lds-server-key.pem" \
  -out "$tmp/mkcert/lds-server.pem" >/dev/null 2>&1
cp "$tmp/mkcert/lds-server.pem" "$tmp/rootca/rootCA.pem"

docker run -d \
  --name "$name" \
  -v "$tmp/mkcert:/etc/mkcert:ro" \
  -v "$tmp/rootca:/etc/share/rootCA:ro" \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)" = healthy ]; then
    docker exec "$name" nginx -t >/dev/null
    docker exec "$name" nginx -v
    docker exec "$name" cat /etc/alpine-release
    exit 0
  fi
  sleep 1
done

docker logs "$name"
exit 1
