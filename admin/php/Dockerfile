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

# Configure sudo and group access for www-data and script-deploy to interact with container socket
RUN addgroup www-data root 2>/dev/null || true && \
    echo "www-data ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    echo "script-deploy ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /var/www/html

