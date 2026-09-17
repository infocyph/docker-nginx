#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
name="nginx-invalid-${RANDOM}"
tmp="$(mktemp -d)"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

make_certs() {
  mkdir -p "$tmp/mkcert" "$tmp/rootca"
  if [ ! -s "$tmp/mkcert/lds-server.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
      -subj '/CN=localhost' \
      -keyout "$tmp/mkcert/lds-server-key.pem" \
      -out "$tmp/mkcert/lds-server.pem" >/dev/null 2>&1
    cp "$tmp/mkcert/lds-server.pem" "$tmp/rootca/rootCA.pem"
  fi
}

make_certs
mkdir -p "$tmp/conf.d"
cat >"$tmp/conf.d/bad.conf" <<'EOF'
server {
  invalid_directive on;
}
EOF

docker run -d \
  --name "$name" \
  -e AUTO_RESTORE_INTERVAL_SECONDS=1 \
  -e MAX_DISABLE_ATTEMPTS=10 \
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

[ ! -e "$tmp/conf.d/bad.conf" ]
[ -e "$tmp/conf.d/bad.conf.disabled" ]
initial_disabled_count="$(find "$tmp/conf.d" -maxdepth 1 -type f -name 'bad.conf.disabled*' | wc -l | tr -d ' ')"
[ "$initial_disabled_count" -eq 1 ]
sleep 3
stable_disabled_count="$(find "$tmp/conf.d" -maxdepth 1 -type f -name 'bad.conf.disabled*' | wc -l | tr -d ' ')"
[ "$stable_disabled_count" -eq 1 ]
[ -e "$tmp/conf.d/bad.conf.disabled" ]

cat >"$tmp/conf.d/bad.conf.disabled" <<'EOF'
server {
  listen 8088;
  location / { return 200 "restored\n"; }
}
EOF

restored=0
for _ in $(seq 1 15); do
  if [ -e "$tmp/conf.d/bad.conf" ] && [ ! -e "$tmp/conf.d/bad.conf.disabled" ]; then
    if [ "$(docker exec "$name" wget -qO- http://127.0.0.1:8088/ 2>/dev/null || true)" = restored ]; then
      restored=1
      break
    fi
  fi
  sleep 1
done
[ "$restored" -eq 1 ]

cat >"$tmp/conf.d/replacement.conf" <<'EOF'
server {
  another_invalid_directive on;
}
EOF

quarantined=0
for _ in $(seq 1 15); do
  if [ ! -e "$tmp/conf.d/replacement.conf" ] && [ -e "$tmp/conf.d/replacement.conf.disabled" ]; then
    quarantined=1
    break
  fi
  sleep 1
done
[ "$quarantined" -eq 1 ]

cat >"$tmp/conf.d/replacement.conf" <<'EOF'
server {
  listen 8089;
  location / { return 200 "replacement\n"; }
}
EOF

replacement_loaded=0
for _ in $(seq 1 15); do
  if [ "$(docker exec "$name" wget -qO- http://127.0.0.1:8089/ 2>/dev/null || true)" = replacement ]; then
    replacement_loaded=1
    break
  fi
  sleep 1
done
[ "$replacement_loaded" -eq 1 ]
[ -e "$tmp/conf.d/replacement.conf.disabled" ]

docker rm -f "$name" >/dev/null

mkdir -p "$tmp/diag-conf"
diag_output="$(docker run --rm \
  -e MAX_DISABLE_ATTEMPTS=garbage \
  -e AUTO_RESTORE_INTERVAL_SECONDS=0 \
  -v "$tmp/diag-conf:/etc/nginx/conf.d" \
  -v "$tmp/mkcert:/etc/mkcert:ro" \
  -v "$tmp/rootca:/etc/share/rootCA:ro" \
  "$image" sh -c 'sleep 1' 2>&1)"
printf '%s\n' "$diag_output" | grep -Fq 'invalid MAX_DISABLE_ATTEMPTS=garbage; defaulting to 100'
printf '%s\n' "$diag_output" | grep -Fq 'invalid AUTO_RESTORE_INTERVAL_SECONDS=0; defaulting to 5'
if printf '%s\n' "$diag_output" | grep -Fq 'started change-aware Nginx config watcher'; then
  echo 'Watcher started for a non-Nginx diagnostic command.' >&2
  exit 1
fi

mkdir -p "$tmp/limit-conf"
for n in 1 2; do
  cat >"$tmp/limit-conf/bad${n}.conf" <<EOF
server {
  invalid_directive_${n} on;
}
EOF
done

set +e
limit_output="$(docker run --rm \
  -e MAX_DISABLE_ATTEMPTS=1 \
  -v "$tmp/limit-conf:/etc/nginx/conf.d" \
  -v "$tmp/mkcert:/etc/mkcert:ro" \
  -v "$tmp/rootca:/etc/share/rootCA:ro" \
  "$image" nginx -t 2>&1)"
limit_status=$?
set -e
[ "$limit_status" -ne 0 ]
printf '%s\n' "$limit_output" | grep -Fq 'too many invalid Nginx conf files to auto-disable'

mkdir -p "$tmp/readonly-conf"
cat >"$tmp/readonly-conf/bad.conf" <<'EOF'
server {
  invalid_readonly_directive on;
}
EOF

set +e
readonly_output="$(docker run --rm \
  -v "$tmp/readonly-conf:/etc/nginx/conf.d:ro" \
  -v "$tmp/mkcert:/etc/mkcert:ro" \
  -v "$tmp/rootca:/etc/share/rootCA:ro" \
  "$image" nginx -t 2>&1)"
readonly_status=$?
set -e
[ "$readonly_status" -ne 0 ]
printf '%s\n' "$readonly_output" | grep -Fq 'cannot quarantine invalid Nginx conf'

printf 'Invalid vhost quarantine and recovery smoke passed.\n'
