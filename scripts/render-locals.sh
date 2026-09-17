#!/bin/sh
set -eu

OUT="/etc/nginx/locals.conf"
LOCALHOST_ROUTES="${LOCALHOST_ROUTES:-}"
LOCALHOST_CLIENT_MAX_BODY_SIZE="${LOCALHOST_CLIENT_MAX_BODY_SIZE:-10G}"
LLM_HOST="llm.localhost"
LLM_UPSTREAM="llm-sm:11434"

PREDEFINED_ROUTES="
admin.localhost server-tools:9911
webmail.localhost mailpit:8025
db.localhost cloud-beaver:8978
ri.localhost redis-insight:5540
me.localhost mongo-express:8081
kibana.localhost kibana:5601
${LLM_HOST} ${LLM_UPSTREAM}
"

case "$LOCALHOST_CLIENT_MAX_BODY_SIZE" in
  *[!0-9kKmMgG]*|'')
    echo "ERROR: invalid LOCALHOST_CLIENT_MAX_BODY_SIZE=$LOCALHOST_CLIENT_MAX_BODY_SIZE" >&2
    exit 1
    ;;
esac

if ! printf '%s\n' "$LOCALHOST_CLIENT_MAX_BODY_SIZE" | grep -Eq '^[1-9][0-9]*[kKmMgG]?$'; then
  echo "ERROR: invalid LOCALHOST_CLIENT_MAX_BODY_SIZE=$LOCALHOST_CLIENT_MAX_BODY_SIZE" >&2
  exit 1
fi
LOCALHOST_CLIENT_MAX_BODY_SIZE="$(printf '%s' "$LOCALHOST_CLIENT_MAX_BODY_SIZE" | tr 'kmg' 'KMG')"

emit_user_routes() {
  [ -n "${LOCALHOST_ROUTES:-}" ] || return 0

  printf '%s' "$LOCALHOST_ROUTES" | awk '
    function valid_label(label) {
      return length(label) >= 1 && length(label) <= 63 &&
             label ~ /^[a-z0-9-]+$/ && label !~ /^-/ && label !~ /-$/
    }
    function valid_localhost(host, labels, count, i) {
      if (length(host) > 253) return 0
      count = split(host, labels, ".")
      if (count < 2 || labels[count] != "localhost") return 0
      for (i = 1; i <= count; i++) {
        if (!valid_label(labels[i])) return 0
      }
      return 1
    }
    function valid_upstream_host(host, labels, count, i) {
      if (length(host) < 1 || length(host) > 253) return 0
      count = split(host, labels, ".")
      for (i = 1; i <= count; i++) {
        if (length(labels[i]) < 1 || length(labels[i]) > 63) return 0
        if (labels[i] !~ /^[a-z0-9_-]+$/) return 0
        if (labels[i] ~ /^[-_]/ || labels[i] ~ /[-_]$/) return 0
      }
      return 1
    }
    BEGIN { RS="," }
    {
      s=$0
      gsub(/\r|\n/, "", s)
      pos = index(s, "=")
      if (pos == 0) next

      host = substr(s, 1, pos - 1)
      upstream = substr(s, pos + 1)
      sub(/^[ \t]+/, "", host); sub(/[ \t]+$/, "", host)
      sub(/^[ \t]+/, "", upstream); sub(/[ \t]+$/, "", upstream)

      if (!valid_localhost(host)) next
      if (match(upstream, /:[0-9]+$/) == 0) next

      upstream_host = substr(upstream, 1, RSTART - 1)
      port = substr(upstream, RSTART + 1)
      if (!valid_upstream_host(upstream_host)) next
      if (port + 0 < 1 || port + 0 > 65535) next

      if (seen[host]++) next
      print host, upstream_host ":" (port + 0)
    }
  '
}

is_predefined_host() {
  h="$1"
  printf '%s\n' "$PREDEFINED_ROUTES" | awk 'NF==2 {print $1}' | grep -qx "$h"
}

build_redirect_server_names() {
  printf '%s\n' "$PREDEFINED_ROUTES" | awk 'NF==2 {print $1}'
  emit_user_routes | awk '{print $1}' | while read -r h; do
    [ -n "${h:-}" ] || continue
    is_predefined_host "$h" && continue
    printf '%s\n' "$h"
  done
}

build_generic_server_names() {
  printf '%s\n' "$PREDEFINED_ROUTES" | awk -v llm="$LLM_HOST" 'NF==2 && $1 != llm {print $1}'
  emit_user_routes | awk '{print $1}' | while read -r h; do
    [ -n "${h:-}" ] || continue
    is_predefined_host "$h" && continue
    printf '%s\n' "$h"
  done
}

flatten_names() {
  awk 'NF{print}' | LC_ALL=C sort -u | awk '{printf "%s ", $0} END{print ""}' | awk '{$1=$1;print}'
}

REDIRECT_SERVER_NAMES="$(build_redirect_server_names | flatten_names)"
GENERIC_SERVER_NAMES="$(build_generic_server_names | flatten_names)"

TMP="${OUT}.tmp.$$"
trap 'rm -f -- "$TMP"' EXIT
: >"$TMP"

cat >>"$TMP" <<EOF
# WebSocket upgrade helper used by /etc/nginx/proxy_websocket.
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ""      "";
}

# Host -> upstream router for generic convenience hosts.
map \$host \$upstream {
  default "";
EOF

printf '%s\n' "$PREDEFINED_ROUTES" | awk 'NF==2 {printf "  %s %s;\n", $1, $2}' >>"$TMP"
emit_user_routes | while read -r host upstream; do
  [ -n "${host:-}" ] || continue
  [ -n "${upstream:-}" ] || continue
  is_predefined_host "$host" && continue
  printf '  %s %s;\n' "$host" "$upstream" >>"$TMP"
done

cat >>"$TMP" <<EOF
}

# Reject unknown HTTP hosts instead of redirecting arbitrary Host values.
server {
  listen 80 default_server;
  server_name _;
  return 404;
  access_log off;
  error_log /dev/null;
}

# Redirect only known convenience hosts, including the reserved LLM host.
server {
  listen 80;
  server_name ${REDIRECT_SERVER_NAMES};
  return 301 https://\$host\$request_uri;
  access_log off;
  error_log /dev/null;
}

# Complete TLS handshake for unknown hosts, then reject the request.
server {
  listen 443 ssl default_server;
  http2 on;
  server_name _;

  ssl_certificate /etc/mkcert/lds-server.pem;
  ssl_certificate_key /etc/mkcert/lds-server-key.pem;
  ssl_trusted_certificate /etc/share/rootCA/rootCA.pem;
  ssl_verify_client off;
  ssl_protocols TLSv1.2 TLSv1.3;

  return 404;
  access_log off;
  error_log /dev/null;
}

# HTTPS router for normal LocalDevStack convenience hosts.
server {
  listen 443 ssl;
  http2 on;
  server_name ${GENERIC_SERVER_NAMES};

  ssl_certificate /etc/mkcert/lds-server.pem;
  ssl_certificate_key /etc/mkcert/lds-server-key.pem;
  ssl_trusted_certificate /etc/share/rootCA/rootCA.pem;
  ssl_verify_client off;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305";
  ssl_prefer_server_ciphers on;

  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  client_max_body_size ${LOCALHOST_CLIENT_MAX_BODY_SIZE};
  client_body_timeout 300s;

  access_log /var/log/nginx/localhost.access.log;
  error_log  /var/log/nginx/localhost.error.log warn;

  gzip on;
  gzip_vary on;
  gzip_static on;
  gzip_proxied any;
  gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/x-javascript application/xml+rss application/vnd.ms-fontobject application/x-font-ttf font/opentype image/svg+xml image/x-icon;

  resolver 127.0.0.11 ipv6=off valid=30s;
  resolver_timeout 2s;

  location = /api/tail {
    if (\$upstream = "") { return 404; }

    include /etc/nginx/proxy_params;
    include /etc/nginx/proxy_timeouts;
    include /etc/nginx/proxy_streaming;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header Connection "";
    gzip off;
    proxy_pass http://\$upstream;
    proxy_redirect off;
  }

  location / {
    if (\$upstream = "") { return 404; }

    include /etc/nginx/proxy_params;
    include /etc/nginx/proxy_timeouts;
    include /etc/nginx/proxy_websocket;
    proxy_set_header Host \$host;
    proxy_pass http://\$upstream;
    proxy_redirect off;
  }
}

# Dedicated Ollama/OpenAI-compatible route. llm-sm is optional and therefore
# resolved lazily by Docker DNS at request time instead of during Nginx startup.
server {
  listen 443 ssl;
  http2 on;
  server_name ${LLM_HOST};

  ssl_certificate /etc/mkcert/lds-server.pem;
  ssl_certificate_key /etc/mkcert/lds-server-key.pem;
  ssl_trusted_certificate /etc/share/rootCA/rootCA.pem;
  ssl_verify_client off;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305";
  ssl_prefer_server_ciphers on;

  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  client_max_body_size ${LOCALHOST_CLIENT_MAX_BODY_SIZE};
  client_body_timeout 300s;

  access_log /var/log/nginx/localhost.access.log;
  error_log  /var/log/nginx/localhost.error.log warn;

  resolver 127.0.0.11 ipv6=off valid=5s;
  resolver_timeout 2s;
  set \$llm_upstream "${LLM_UPSTREAM}";

  location / {
    include /etc/nginx/proxy_params;
    include /etc/nginx/proxy_timeouts;
    include /etc/nginx/proxy_streaming;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header Connection "";
    gzip off;
    proxy_pass http://\$llm_upstream;
    proxy_redirect off;
  }
}
EOF

if ! cmp -s "$TMP" "$OUT"; then
  mv "$TMP" "$OUT"
else
  rm -f "$TMP"
fi
trap - EXIT
