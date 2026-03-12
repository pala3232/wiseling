FROM nginx:alpine

COPY index.html /usr/share/nginx/html/index.html

# Inject API_BASE from env at runtime via envsubst
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
