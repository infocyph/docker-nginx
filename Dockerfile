FROM nginx:alpine
LABEL org.opencontainers.image.source="https://github.com/infocyph/docker-nginx"
LABEL org.opencontainers.image.description="NGINX with updated params"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"

RUN apk add --no-cache bash tzdata figlet ncurses musl-locales gawk && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

COPY scripts/fcgi-params.sh /usr/local/bin/fcgi_params.sh
COPY scripts/proxy-params.sh /usr/local/bin/proxy_params.sh
ADD https://raw.githubusercontent.com/infocyph/Scriptomatic/master/bash/banner.sh /usr/local/bin/show-banner
ADD https://raw.githubusercontent.com/infocyph/Toolset/main/ChromaCat/chromacat /usr/local/bin/chromacat

RUN set -eux; \
    chmod +x /usr/local/bin/fcgi_params.sh /usr/local/bin/proxy_params.sh /usr/local/bin/show-banner /usr/local/bin/chromacat; \
    mkdir -p /etc/share/rootCA /etc/mkcert; \
    NGINX_CONF="/etc/nginx/nginx.conf"; \
    if ! grep -q 'map $http_upgrade $connection_upgrade' "$NGINX_CONF"; then \
      sed -i '/^[[:space:]]*include[[:space:]]\+\/etc\/nginx\/conf\.d\/\*\.conf;[[:space:]]*$/i\
    map $http_upgrade $connection_upgrade {\
      default upgrade;\
      ""      close;\
    }\
' "$NGINX_CONF"; \
    fi; \
    /usr/local/bin/fcgi_params.sh; \
    /usr/local/bin/proxy_params.sh; \
    mkdir -p /etc/profile.d; \
    { \
      echo '#!/bin/sh'; \
      echo 'if [ -n "$PS1" ] && [ -z "${BANNER_SHOWN-}" ]; then'; \
      echo '  export BANNER_SHOWN=1'; \
      echo "  NGINX_VERSION=\$(nginx -v 2>&1 | sed -n 's|^nginx version: nginx/\([0-9\.]*\).*|\1|p')"; \
      echo '  show-banner "Nginx ${NGINX_VERSION}"'; \
      echo 'fi'; \
    } > /etc/profile.d/banner-hook.sh; \
    chmod +x /etc/profile.d/banner-hook.sh; \
    { \
      echo 'if [ -n "$PS1" ] && [ -z "${BANNER_SHOWN-}" ]; then'; \
      echo '  export BANNER_SHOWN=1'; \
      echo '  show-banner "Nginx ${NGINX_VERSION}"'; \
      echo 'fi'; \
    } >> /root/.bashrc; \
    nginx -t

EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
