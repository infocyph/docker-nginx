#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/tests/fixtures/mock-upstream/server.py"
network="nginx-route-${RANDOM}"
proxy="nginx-route-proxy-${RANDOM}"
mock="nginx-route-mock-${RANDOM}"
tmp="$(mktemp -d)"

cleanup() {
  docker rm -f "$proxy" "$mock" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

http_port="$(free_port)"
https_port="$(free_port)"
mkdir -p "$tmp/mkcert" "$tmp/rootca"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=localhost' \
  -keyout "$tmp/mkcert/lds-server-key.pem" \
  -out "$tmp/mkcert/lds-server.pem" >/dev/null 2>&1
cp "$tmp/mkcert/lds-server.pem" "$tmp/rootca/rootCA.pem"

docker pull python:3.13-alpine >/dev/null
docker network create "$network" >/dev/null

docker run -d \
  --name "$mock" \
  --network "$network" \
  --network-alias server-tools \
  -e PORT=9911 \
  -v "$fixture:/server.py:ro" \
  python:3.13-alpine python /server.py >/dev/null

docker run -d \
  --name "$proxy" \
  --network "$network" \
  -p "127.0.0.1:${http_port}:80" \
  -p "127.0.0.1:${https_port}:443" \
  -v "$tmp/mkcert:/etc/mkcert:ro" \
  -v "$tmp/rootca:/etc/share/rootCA:ro" \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' "$proxy" 2>/dev/null || true)" = healthy ]; then
    break
  fi
  sleep 1
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$proxy")" = healthy ]

code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: unknown.localhost' "http://127.0.0.1:${http_port}/")"
[ "$code" = 404 ]

headers="$(curl -sS -D - -o /dev/null -H 'Host: admin.localhost' "http://127.0.0.1:${http_port}/inspect")"
printf '%s\n' "$headers" | grep -Eq '^HTTP/1\.[01] 301'
printf '%s\n' "$headers" | grep -Fiq 'location: https://admin.localhost/inspect'

code="$(curl -skS -o /dev/null -w '%{http_code}' \
  --resolve "unknown.localhost:${https_port}:127.0.0.1" \
  "https://unknown.localhost:${https_port}/")"
[ "$code" = 404 ]

response=''
for _ in $(seq 1 30); do
  response="$(curl -skS \
    --resolve "admin.localhost:${https_port}:127.0.0.1" \
    "https://admin.localhost:${https_port}/inspect" || true)"
  if printf '%s' "$response" | grep -Fq '"host":"admin.localhost"'; then
    break
  fi
  sleep 1
done

printf '%s' "$response" | grep -Fq '"host":"admin.localhost"'
printf '%s' "$response" | grep -Fq '"forwarded_host":"admin.localhost"'
printf '%s' "$response" | grep -Fq '"forwarded_proto":"https"'
printf '%s' "$response" | grep -Fq '"forwarded_port":"443"'
printf '%s' "$response" | grep -Fq '"request_id_present":true'
printf '%s' "$response" | grep -Fq '"connection":""'

tls12_response="$(curl -skS --tlsv1.2 --tls-max 1.2 \
  --resolve "admin.localhost:${https_port}:127.0.0.1" \
  "https://admin.localhost:${https_port}/inspect")"
printf '%s' "$tls12_response" | grep -Fq '"host":"admin.localhost"'

ws_response="$(curl -skS --http1.1 \
  --resolve "admin.localhost:${https_port}:127.0.0.1" \
  -H 'Upgrade: websocket' \
  -H 'Connection: Upgrade' \
  "https://admin.localhost:${https_port}/inspect")"
printf '%s' "$ws_response" | grep -Fq '"connection":"upgrade"'
printf '%s' "$ws_response" | grep -Fq '"upgrade":"websocket"'

out="$tmp/tail.out"
curl -skN \
  --resolve "admin.localhost:${https_port}:127.0.0.1" \
  "https://admin.localhost:${https_port}/api/tail" >"$out" &
pid=$!
seen=0
for _ in $(seq 1 20); do
  if grep -Fq '"chunk":1' "$out"; then
    seen=1
    break
  fi
  sleep 0.1
done
[ "$seen" -eq 1 ]
kill -0 "$pid"
! grep -Fq '"chunk":2' "$out"
wait "$pid"
grep -Fq '"chunk":2' "$out"

printf 'Live convenience route smoke passed.\n'
