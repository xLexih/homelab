FROM nginxinc/nginx-unprivileged:alpine
COPY src/index.html /usr/share/nginx/html/index.html
COPY src/nginx.conf /etc/nginx/conf.d/default.conf
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost:8080 || exit 1
