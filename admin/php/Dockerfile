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

# Configure sudo for all users inside container without password
RUN mkdir -p /etc/sudoers.d && \
    echo "ALL ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd && \
    chmod 0440 /etc/sudoers.d/nopasswd && \
    addgroup www-data root 2>/dev/null || true

# Configure PHP-FPM to run as root so it has direct access to docker socket and files
RUN sed -i 's/user = www-data/user = root/g' /usr/local/etc/php-fpm.d/www.conf 2>/dev/null || true && \
    sed -i 's/group = www-data/group = root/g' /usr/local/etc/php-fpm.d/www.conf 2>/dev/null || true

WORKDIR /var/www/html

CMD ["php-fpm", "-R"]

