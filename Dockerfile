# Dockerfile
FROM nginx:1.27-alpine
# SPA-Fallback + kleine Hardening-Header
COPY nginx.conf /etc/nginx/conf.d/default.conf
# NUR die gebauten Dateien ins Image
COPY dist/spa /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
