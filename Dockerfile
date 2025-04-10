FROM nginx:mainline-alpine
LABEL org.opencontainers.image.source="https://github.com/infocyph/docker-nginx"
LABEL org.opencontainers.image.description="NGINX with updated params"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="infocyph,abmmhasan"
RUN apk add --no-cache bash
COPY scripts/fcgi-params.sh /usr/local/bin/fcgi_params.sh
COPY scripts/proxy-params.sh /usr/local/bin/proxy_params.sh
RUN mkdir -p /etc/share/rootCA /etc/mkcert && \
    chmod +x /usr/local/bin/fcgi_params.sh /usr/local/bin/proxy_params.sh && \
    /usr/local/bin/fcgi_params.sh && \
    /usr/local/bin/proxy_params.sh
EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
