FROM nginx:1.27-alpine

RUN rm /etc/nginx/conf.d/default.conf 2>/dev/null || true
COPY nginx.conf /etc/nginx/nginx.conf

RUN chown -R nginx:nginx /var/cache/nginx /etc/nginx

USER nginx
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s CMD wget -q -O- http://localhost:8080/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
