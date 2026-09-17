#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"

docker run --rm --entrypoint sh "$image" -ec '
  cat > /etc/nginx/locals.conf <<"EOF"
map $http_upgrade $connection_upgrade {
  default upgrade;
  "" "";
}
EOF

  cat > /etc/nginx/conf.d/include-smoke.conf <<"EOF"
server {
  listen 8080;
  server_name fastcgi-smoke.localhost;

  location / {
    include /etc/nginx/fastcgi_params;
    include /etc/nginx/fastcgi_streaming;
    fastcgi_pass 127.0.0.1:9000;
  }
}

server {
  listen 8081;
  server_name proxy-smoke.localhost;

  location / {
    include /etc/nginx/proxy_params;
    include /etc/nginx/proxy_timeouts;
    include /etc/nginx/proxy_buffers;
    include /etc/nginx/proxy_websocket;
    proxy_pass http://127.0.0.1:9001;
  }
}
EOF

  nginx -t
'

printf 'Generated include syntax smoke passed.\n'
