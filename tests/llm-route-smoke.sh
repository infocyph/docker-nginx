#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/tests/fixtures/mock-upstream/server.py"
network="nginx-llm-${RANDOM}"
proxy="nginx-llm-proxy-${RANDOM}"
mock="nginx-llm-mock-${RANDOM}"
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

assert_streams() {
  local path="$1" payload="$2" out="$3" pid seen

  curl -skN --http1.1 \
    --resolve "llm.localhost:${https_port}:127.0.0.1" \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "https://llm.localhost:${https_port}${path}" >"$out" &
  pid=$!

  seen=0
  for _ in $(seq 1 20); do
    if grep -Fq '"chunk":1' "$out"; then
      seen=1
      break
    fi
    sleep 0.1
  done

  if [ "$seen" -ne 1 ]; then
    echo "First streaming chunk was not observable before completion for $path" >&2
    wait "$pid" || true
    return 1
  fi

  kill -0 "$pid"
  ! grep -Fq '"chunk":2' "$out"
  wait "$pid"

  if [[ "$path" == /v1/* ]]; then
    grep -Fq 'data: [DONE]' "$out"
  else
    grep -Fq '"chunk":2' "$out"
  fi

  grep -Fq "\"path\":\"${path}\"" "$out"
  grep -Fq '"host":"llm.localhost"' "$out"
  grep -Fq '"forwarded_host":"llm.localhost"' "$out"
  grep -Fq '"forwarded_proto":"https"' "$out"
  grep -Fq '"forwarded_port":"443"' "$out"
  grep -Fq '"request_id_present":true' "$out"
  grep -Fq '"connection":""' "$out"
  grep -Fq '"model":"mock"' "$out"
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
  --name "$proxy" \
  --network "$network" \
  -p "127.0.0.1:${http_port}:80" \
  -p "127.0.0.1:${https_port}:443" \
  -e LOCALHOST_ROUTES='llm.localhost=evil:9999' \
  -e LLM_PROXY_TIMEOUT_SECONDS=7 \
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

docker exec "$proxy" grep -Fq 'proxy_send_timeout    7s;' /etc/nginx/locals.conf
docker exec "$proxy" grep -Fq 'proxy_read_timeout    7s;' /etc/nginx/locals.conf
llm_block="$(docker exec "$proxy" awk '/server_name llm\.localhost;/{capture=1} capture{print} capture && /^}/{exit}' /etc/nginx/locals.conf)"
if grep -Fq 'include /etc/nginx/proxy_timeouts;' <<<"$llm_block"; then
  echo 'LLM route unexpectedly inherited the generic proxy_timeouts include.' >&2
  exit 1
fi

headers="$(curl -sS -D - -o /dev/null -H 'Host: llm.localhost' "http://127.0.0.1:${http_port}/api/tags")"
printf '%s\n' "$headers" | grep -Eq '^HTTP/1\.[01] 301'
printf '%s\n' "$headers" | grep -Fiq 'location: https://llm.localhost/api/tags'

missing_code="$(curl -skS --max-time 6 -o /dev/null -w '%{http_code}' \
  --resolve "llm.localhost:${https_port}:127.0.0.1" \
  "https://llm.localhost:${https_port}/api/tags" || true)"
[ "$missing_code" = 502 ]

docker run -d \
  --name "$mock" \
  --network "$network" \
  --network-alias llm-sm \
  -e PORT=11434 \
  -e STREAM_DELAY_SECONDS=3 \
  -v "$fixture:/server.py:ro" \
  python:3.13-alpine python /server.py >/dev/null

ready=0
for _ in $(seq 1 20); do
  code="$(curl -skS --max-time 5 -o "$tmp/tags.json" -w '%{http_code}' \
    --resolve "llm.localhost:${https_port}:127.0.0.1" \
    "https://llm.localhost:${https_port}/api/tags" || true)"
  if [ "$code" = 200 ]; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" -eq 1 ]
grep -Fq '"name":"mock:latest"' "$tmp/tags.json"

version="$(curl -skS \
  --resolve "llm.localhost:${https_port}:127.0.0.1" \
  "https://llm.localhost:${https_port}/api/version")"
printf '%s' "$version" | grep -Fq '"version":"mock"'

assert_streams '/api/chat' '{"model":"mock","messages":[{"role":"user","content":"hello"}]}' "$tmp/chat.out"
assert_streams '/api/generate' '{"model":"mock","prompt":"hello"}' "$tmp/generate.out"
assert_streams '/v1/chat/completions' '{"model":"mock","messages":[{"role":"user","content":"hello"}],"stream":true}' "$tmp/v1.out"

printf 'LLM route streaming and late-start DNS recovery smoke passed.\n'
