#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/tests/fixtures/mock-upstream/server.py"
network="nginx-llm-${RANDOM}"
proxy="nginx-llm-proxy-${RANDOM}"
ollama_mock="nginx-llm-ollama-${RANDOM}"
fastflow_mock="nginx-llm-fastflow-${RANDOM}"
tmp="$(mktemp -d)"

cleanup() {
  docker rm -f "$proxy" "$ollama_mock" "$fastflow_mock" >/dev/null 2>&1 || true
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

https_code() {
  local host="$1" path="$2"
  curl -skS --max-time 6 -o /dev/null -w '%{http_code}'     --resolve "${host}:${https_port}:127.0.0.1"     "https://${host}:${https_port}${path}" || true
}

wait_https_code() {
  local host="$1" path="$2" expected="$3" code=""
  for _ in $(seq 1 20); do
    code="$(https_code "$host" "$path")"
    [[ "$code" == "$expected" ]] && return 0
    sleep 1
  done
  printf 'Expected %s%s -> %s, last code=%s\n' "$host" "$path" "$expected" "$code" >&2
  return 1
}

https_stream() {
  local host="$1" path="$2" payload="$3" out="$4" pid seen

  curl -skN --http1.1     --resolve "${host}:${https_port}:127.0.0.1"     -H 'Content-Type: application/json'     --data "$payload"     "https://${host}:${https_port}${path}" >"$out" &
  pid=$!

  seen=0
  for _ in $(seq 1 20); do
    if grep -Fq '"chunk":1' "$out"; then
      seen=1
      break
    fi
    sleep 0.1
  done
  [[ "$seen" -eq 1 ]] || {
    echo "First streaming chunk was not observable for $host$path" >&2
    wait "$pid" || true
    return 1
  }

  kill -0 "$pid"
  wait "$pid"
  grep -Fq 'data: [DONE]' "$out"
  grep -Fq "\"path\":\"${path}\"" "$out"
  grep -Fq "\"host\":\"${host}\"" "$out"
  grep -Fq "\"forwarded_host\":\"${host}\"" "$out"
  grep -Fq '"forwarded_proto":"https"' "$out"
  grep -Fq '"forwarded_port":"443"' "$out"
  grep -Fq '"request_id_present":true' "$out"
  grep -Fq '"connection":""' "$out"
}

http_port="$(free_port)"
https_port="$(free_port)"
native_port="$(free_port)"
mkdir -p "$tmp/mkcert" "$tmp/rootca"
openssl req -x509 -newkey rsa:2048 -nodes -days 1   -subj '/CN=localhost'   -keyout "$tmp/mkcert/lds-server-key.pem"   -out "$tmp/mkcert/lds-server.pem" >/dev/null 2>&1
cp "$tmp/mkcert/lds-server.pem" "$tmp/rootca/rootCA.pem"

docker pull python:3.13-alpine >/dev/null
docker network create "$network" >/dev/null

docker run -d   --name "$proxy"   --network "$network"   -p "127.0.0.1:${http_port}:80"   -p "127.0.0.1:${https_port}:443"   -p "127.0.0.1:${native_port}:11434"   -e LOCALHOST_ROUTES='llm.localhost=evil:9999,llm-ollama.localhost=evil:9999,llm-fastflow.localhost=evil:9999'   -e LLM_PROXY_TIMEOUT_SECONDS=7   -v "$tmp/mkcert:/etc/mkcert:ro"   -v "$tmp/rootca:/etc/share/rootCA:ro"   "$image" >/dev/null

for _ in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$proxy" 2>/dev/null || true)" == healthy ]] && break
  sleep 1
done
[[ "$(docker inspect -f '{{.State.Health.Status}}' "$proxy")" == healthy ]]

docker exec "$proxy" grep -Fq 'proxy_send_timeout    7s;' /etc/nginx/locals.conf
docker exec "$proxy" grep -Fq 'proxy_read_timeout    7s;' /etc/nginx/locals.conf
docker exec "$proxy" grep -Fq 'llm.localhost llm:11434;' /etc/nginx/locals.conf
docker exec "$proxy" grep -Fq 'llm-ollama.localhost llm-ollama:11434;' /etc/nginx/locals.conf
docker exec "$proxy" grep -Fq 'llm-fastflow.localhost llm-fastflow:11434;' /etc/nginx/locals.conf

# Reserved HTTP identities always redirect, even before the selected provider starts.
for host in llm.localhost llm-ollama.localhost llm-fastflow.localhost; do
  headers="$(curl -sS -D - -o /dev/null -H "Host: $host" "http://127.0.0.1:${http_port}/v1/models")"
  printf '%s\n' "$headers" | grep -Eq '^HTTP/1\.[01] 301'
  printf '%s\n' "$headers" | grep -Fiq "location: https://${host}/v1/models"
  [[ "$(https_code "$host" /v1/models)" == 502 ]]
done

native_missing="$(curl -sS --max-time 6 -o /dev/null -w '%{http_code}'   -H 'Host: llm.localhost'   "http://127.0.0.1:${native_port}/v1/models" || true)"
[[ "$native_missing" == 502 ]]

# Phase 1: Ollama is the only active provider. It owns the common alias plus its
# provider-specific alias. FastFlow must remain unavailable.
docker run -d   --name "$ollama_mock"   --network "$network"   --network-alias llm   --network-alias llm-ollama   -e PORT=11434   -e STREAM_DELAY_SECONDS=3   -v "$fixture:/server.py:ro"   python:3.13-alpine python /server.py >/dev/null

wait_https_code llm.localhost /v1/models 200
wait_https_code llm-ollama.localhost /v1/models 200
wait_https_code llm-fastflow.localhost /v1/models 502

ollama_tags="$(curl -skS   --resolve "llm-ollama.localhost:${https_port}:127.0.0.1"   "https://llm-ollama.localhost:${https_port}/api/tags")"
printf '%s' "$ollama_tags" | grep -Fq '"name":"mock:latest"'

https_stream 'llm.localhost' '/v1/chat/completions'   '{"model":"mock","messages":[{"role":"user","content":"hello"}],"stream":true}'   "$tmp/ollama-common.out"
https_stream 'llm-ollama.localhost' '/v1/chat/completions'   '{"model":"mock","messages":[{"role":"user","content":"hello"}],"stream":true}'   "$tmp/ollama-provider.out"

native_models="$(curl -sS --max-time 5   -H 'Host: llm.localhost'   "http://127.0.0.1:${native_port}/v1/models")"
printf '%s' "$native_models" | grep -Fq '"id":"mock"'
printf '%s' "$native_models" | grep -Fq '"forwarded_proto":"http"'
printf '%s' "$native_models" | grep -Fq '"forwarded_port":"11434"'

# Remove Ollama completely before FastFlow appears. The two providers are never
# present at the same time.
docker rm -f "$ollama_mock" >/dev/null
wait_https_code llm.localhost /v1/models 502
wait_https_code llm-ollama.localhost /v1/models 502

# Phase 2: FastFlow is the only active provider. LocalDevStack normalizes its
# server port to 11434 and gives it the common llm alias.
docker run -d   --name "$fastflow_mock"   --network "$network"   --network-alias llm   --network-alias llm-fastflow   -e PORT=11434   -e STREAM_DELAY_SECONDS=3   -v "$fixture:/server.py:ro"   python:3.13-alpine python /server.py >/dev/null

wait_https_code llm.localhost /v1/models 200
wait_https_code llm-fastflow.localhost /v1/models 200
wait_https_code llm-ollama.localhost /v1/models 502

https_stream 'llm.localhost' '/v1/chat/completions'   '{"model":"mock","messages":[{"role":"user","content":"hello"}],"stream":true}'   "$tmp/fastflow-common.out"
https_stream 'llm-fastflow.localhost' '/v1/chat/completions'   '{"model":"mock","messages":[{"role":"user","content":"hello"}],"stream":true}'   "$tmp/fastflow-provider.out"

native_models="$(curl -sS --max-time 5   -H 'Host: llm.localhost'   "http://127.0.0.1:${native_port}/v1/models")"
printf '%s' "$native_models" | grep -Fq '"id":"mock"'

printf 'Mutually exclusive Ollama/FastFlow LLM routing smoke passed.\n'
