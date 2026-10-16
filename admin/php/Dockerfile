FROM php:8.3-fpm-alpine

# Install system dependencies, MySQL client tools, and Docker CLI
RUN apk add --no-cache \
    bash \
    mariadb-client \
    docker-cli \
    docker-cli-compose \
    sudo \
    curl \
    coreutils

# Install PHP extensions required for PDO MySQL and WordPress management
RUN docker-php-ext-install pdo pdo_mysql mysqli

# Setup script-deploy user inside container (matching UID 1000 if needed)
RUN adduser -D -s /bin/bash script-deploy || true

WORKDIR /var/www/html

