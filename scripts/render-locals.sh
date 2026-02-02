#!/bin/sh
set -eu

OUT="/etc/nginx/locals.conf"

# Non-overridable defaults (edit here)
# Format: "host upstream"
PREDEFINED_ROUTES='
webmail.localhost mailpit:8025
db.localhost cloud-beaver:8978
'

LOCALHOST_ROUTES="${LOCALHOST_ROUTES:-}"

emit_user_routes() {
  [ -n "$LOCALHOST_ROUTES" ] || return 0
  echo "$LOCALHOST_ROUTES" | tr ',' '\n' | while IFS='=' read -r host upstream; do
    host="$(echo "${host:-}" | tr -d ' \t\r\n')"
    upstream="$(echo "${upstream:-}" | tr -d ' \t\r\n')"
    [ -n "$host" ] && [ -n "$upstream" ] && printf '%s %s\n' "$host" "$upstream"
  done
}

is_predefined_host() {
  h="$1"
  echo "$PREDEFINED_ROUTES" | awk 'NF==2 {print $1}' | grep -qx "$h"
}

TMP="${OUT}.tmp"
: > "$TMP"

cat >>"$TMP" <<'EOF'
map $http_upgrade $connection_upgrade {
  default upgrade;
  ""      close;
}

map $host $upstream {
  default "";
EOF

# predefined first
echo "$PREDEFINED_ROUTES" | awk 'NF==2 {printf "  %s %s;\n",$1,$2}' >>"$TMP"

# user routes (additive only, cannot override predefined)
emit_user_routes | while read -r host upstream; do
  if is_predefined_host "$host"; then
    continue
  fi
  printf '  %s %s;\n' "$host" "$upstream" >>"$TMP"
done

cat >>"$TMP" <<'EOF'
}

server {
  listen 80;
  server_name *.localhost;

  if ($upstream = "") { return 404; }

  location / {
    include /etc/nginx/proxy_params;
    proxy_pass http://$upstream;
  }
}
EOF

mv "$TMP" "$OUT"
