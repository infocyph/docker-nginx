FROM nginx:alpine
LABEL org.opencontainers.image.source="https://github.com/infocyph/docker-nginx"
LABEL org.opencontainers.image.description="NGINX with updated params"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"

ARG TZ=Asia/Dhaka

RUN apk add --no-cache \
      bash \
      ca-certificates \
      tzdata \
      figlet \
      ncurses \
      musl-locales \
      gawk \
    && apk add --no-cache --virtual .fetch-deps curl \
    && update-ca-certificates \
    && rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=${TZ}

COPY scripts/fcgi-params.sh /usr/local/bin/fcgi_params.sh
COPY scripts/proxy-params.sh /usr/local/bin/proxy_params.sh
COPY scripts/render-locals.sh /usr/local/bin/render-locals
COPY scripts/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint
COPY scripts/nginx-healthcheck.sh /usr/local/bin/nginx-healthcheck

RUN set -eux; \
    curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 \
      "https://raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh" \
      -o /usr/local/bin/show-banner; \
    test -s /usr/local/bin/show-banner; \
    bash -n /usr/local/bin/show-banner; \
    curl -fsSLo /tmp/toolset-install.sh \
      "https://github.com/infocyph/Toolset/releases/latest/download/install.sh"; \
    test -s /tmp/toolset-install.sh; \
    bash -n /tmp/toolset-install.sh; \
    bash /tmp/toolset-install.sh --prefix /usr/local/bin chromacat; \
    chromacat --version; \
    rm -f /tmp/toolset-install.sh; \
    chmod +x \
      /usr/local/bin/fcgi_params.sh \
      /usr/local/bin/proxy_params.sh \
      /usr/local/bin/render-locals \
      /usr/local/bin/nginx-entrypoint \
      /usr/local/bin/nginx-healthcheck \
      /usr/local/bin/show-banner \
      /usr/local/bin/chromacat; \
    rm -f /etc/nginx/conf.d/default.conf; \
    mkdir -p /etc/share/rootCA /etc/mkcert /var/log/nginx; \
    chmod 0755 /var/log/nginx; \
    NGINX_CONF="/etc/nginx/nginx.conf"; \
    if ! grep -q 'include /etc/nginx/locals.conf;' "$NGINX_CONF"; then \
      sed -i '/^[[:space:]]*include[[:space:]]\+\/etc\/nginx\/conf\.d\/\*\.conf;[[:space:]]*$/i\
    include /etc/nginx/locals.conf;\
' "$NGINX_CONF"; \
    fi; \
    test "$(grep -Fc 'include /etc/nginx/locals.conf;' "$NGINX_CONF")" -eq 1; \
    test -f /etc/nginx/locals.conf || : > /etc/nginx/locals.conf; \
    /usr/local/bin/fcgi_params.sh; \
    sha256sum /etc/nginx/fastcgi_params /etc/nginx/fastcgi_streaming > /tmp/fcgi.sha256; \
    /usr/local/bin/fcgi_params.sh; \
    sha256sum -c /tmp/fcgi.sha256; \
    /usr/local/bin/proxy_params.sh; \
    sha256sum \
      /etc/nginx/proxy_params \
      /etc/nginx/proxy_fixedip_headers \
      /etc/nginx/proxy_timeouts \
      /etc/nginx/proxy_buffers \
      /etc/nginx/proxy_websocket \
      /etc/nginx/proxy_streaming \
      /etc/nginx/proxy_csp_relax \
      /etc/nginx/proxy_h2_sanitize > /tmp/proxy.sha256; \
    /usr/local/bin/proxy_params.sh; \
    sha256sum -c /tmp/proxy.sha256; \
    rm -f \
      /tmp/fcgi.sha256 \
      /tmp/proxy.sha256 \
      /etc/nginx/*.bak \
      /usr/local/bin/fcgi_params.sh \
      /usr/local/bin/proxy_params.sh; \
    mkdir -p /etc/profile.d; \
    { \
      echo '#!/bin/sh'; \
      echo 'case "$-" in *i*) ;; *) return 0 ;; esac'; \
      echo '[ -z "${BANNER_SHOWN-}" ] || return 0'; \
      echo 'command -v show-banner >/dev/null 2>&1 || return 0'; \
      echo 'BANNER_SHOWN=1'; \
      echo 'export BANNER_SHOWN'; \
      echo 'NGINX_VERSION="$(nginx -v 2>&1 | sed -n '\''s|^nginx version: nginx/\([0-9.]*\).*|\1|p'\'')"'; \
      echo 'show-banner "Nginx ${NGINX_VERSION:-unknown}"'; \
    } > /etc/profile.d/banner-hook.sh; \
    chmod +x /etc/profile.d/banner-hook.sh; \
    printf '\n[ -r /etc/profile.d/banner-hook.sh ] && . /etc/profile.d/banner-hook.sh\n' >> /root/.bashrc; \
    apk del .fetch-deps; \
    nginx -t

EXPOSE 80 443

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 CMD ["nginx-healthcheck"]
ENTRYPOINT ["nginx-entrypoint"]
CMD ["nginx", "-g", "daemon off;"]
