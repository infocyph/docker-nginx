#!/bin/sh
set -eu

OUT="/etc/nginx/locals.conf"

# Non-overridable defaults (edit here)
# Format: "host upstream"
PREDEFINED_ROUTES='
webmail.localhost mailpit:8025
db.localhost cloud-beaver:8978
ri.localhost redis-insight:5540
me.localhost mongo-express:8081
kibana.localhost kibana:5601
'

# Additive user routes: "a.localhost=svc:port,b.localhost=svc:port"
LOCALHOST_ROUTES="${LOCALHOST_ROUTES:-}"

emit_user_routes() {
  [ -n "${LOCALHOST_ROUTES:-}" ] || return 0

  # Output: "<host> <upstream>"
  printf '%s' "$LOCALHOST_ROUTES" | awk '
    BEGIN { RS="," }
    {
      s=$0
      gsub(/\r|\n/, "", s)
      pos = index(s, "=")
      if (pos == 0) next

      host = substr(s, 1, pos-1)
      upstream = substr(s, pos+1)

      sub(/^[ \t]+/, "", host); sub(/[ \t]+$/, "", host)
      sub(/^[ \t]+/, "", upstream); sub(/[ \t]+$/, "", upstream)

      if (host == "" || upstream == "") next
      if (host !~ /^[a-z0-9.-]+$/) next
      if (upstream !~ /^[a-z0-9.-]+:[0-9]+$/) next

      # dedupe by host (keep first occurrence)
      if (seen[host]++) next

      print host, upstream
    }
  '
}

is_predefined_host() {
  h="$1"
  echo "$PREDEFINED_ROUTES" | awk 'NF==2 {print $1}' | grep -qx "$h"
}

# Build server_name list (predefined + user, user cannot override predefined)
build_server_names() {
  # predefined first
  echo "$PREDEFINED_ROUTES" | awk 'NF==2 {print $1}'
  # then user hosts (filtered)
  emit_user_routes | awk '{print $1}' | while read -r h; do
    [ -n "${h:-}" ] || continue
    if is_predefined_host "$h"; then
      continue
    fi
    echo "$h"
  done
}

# Flatten list to one line: "a b c"
SERVER_NAMES="$(build_server_names | awk 'NF{print}' | LC_ALL=C sort -u | awk '{printf "%s ", $0} END{print ""}')"
SERVER_NAMES="$(printf '%s' "$SERVER_NAMES" | awk '{$1=$1;print}')" # trim

TMP="${OUT}.tmp"
: >"$TMP"

cat >>"$TMP" <<EOF
# Required by /etc/nginx/proxy_websocket
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ""      close;
}

# Host -> Upstream map (router)
map \$host \$upstream {
  default "";
EOF

# predefined first (cannot be overridden)
echo "$PREDEFINED_ROUTES" | awk 'NF==2 {printf "  %s %s;\n",$1,$2}' >>"$TMP"

# user routes (additive only, cannot override predefined)
emit_user_routes | while read -r host upstream; do
  [ -n "${host:-}" ] || continue
  [ -n "${upstream:-}" ] || continue
  if is_predefined_host "$host"; then
    continue
  fi
  printf '  %s %s;\n' "$host" "$upstream" >>"$TMP"
done

cat >>"$TMP" <<EOF
}

# Safe access log filename (host[:port] -> host)
map \$http_host \$log_host {
  default "invalid-host";
  ~^(?<h>[a-z0-9.-]+)(?::\\d+)?\$ \$h;
}

# Redirect only for routed hosts (NOT wildcard)
server {
  listen 80;
  server_name ${SERVER_NAMES};
  return 301 https://\$host\$request_uri;
  access_log off;
  error_log /dev/null;
}

# HTTPS router only for routed hosts (NOT wildcard)
server {
  listen 443 ssl;
  http2 on;
  server_name ${SERVER_NAMES};

  ssl_certificate /etc/mkcert/nginx-proxy.pem;
  ssl_certificate_key /etc/mkcert/nginx-proxy-key.pem;
  ssl_trusted_certificate /etc/share/rootCA/rootCA.pem;
  ssl_verify_client off;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers "TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA:AES128-SHA";
  ssl_prefer_server_ciphers on;

  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  client_max_body_size 10G;
  client_body_timeout 300s;

  access_log /var/log/nginx/\$log_host.access.log;
  error_log  /var/log/nginx/localhost.error.log warn;

  gzip on;
  gzip_vary on;
  gzip_static on;
  gzip_proxied any;
  gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/x-javascript application/xml+rss application/vnd.ms-fontobject application/x-font-ttf font/opentype image/svg+xml image/x-icon;

  # REQUIRED when proxy_pass uses a variable
  resolver 127.0.0.11 ipv6=off valid=30s;
  resolver_timeout 2s;

  location / {
    include /etc/nginx/proxy_params;

    # \$upstream is always set for these server_names, but keep safety:
    if (\$upstream = "") { return 404; }

    proxy_pass http://\$upstream;
    proxy_redirect off;
  }
}
EOF

mv "$TMP" "$OUT"
