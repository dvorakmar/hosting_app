#!/usr/bin/env bash
# ==============================================================================
# Provisioning Script - Automatizované vytvoření WordPress instance
# ==============================================================================
# Použití: ./provision.sh <site_name>
# Příklad: ./provision.sh web1
# ==============================================================================

set -euo pipefail

# --- Zjištění cest ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detekce kořenového adresáře projektu (na hostiteli i v kontejneru)
if [ -n "${PROJECT_ROOT:-}" ] && [ -d "${PROJECT_ROOT}" ] && [ "${PROJECT_ROOT}" != "/" ]; then
    PROJECT_ROOT="${PROJECT_ROOT}"
elif [ "$SCRIPT_DIR" = "/scripts" ]; then
    # Běžíme uvnitř kontejneru PHP-FPM
    if [ -d "/opt/own_hosting" ]; then
        PROJECT_ROOT="/opt/own_hosting"
    elif [ -d "/workspace" ]; then
        PROJECT_ROOT="/workspace"
    else
        PROJECT_ROOT=""
    fi
else
    # Běžíme přímo na hostitelském stroji
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# --- Načtení proměnných z .env ---
ENV_FILE="${PROJECT_ROOT}/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="/.env"

if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//" | sed "s/^[\"']//;s/[\"']$//")
        export "$key=$value" 2>/dev/null || true
    done < "$ENV_FILE"
fi

# Zaručení absolutních platných cest odvozených z PROJECT_ROOT (nepřepsatelných z .env)
if [ -n "$PROJECT_ROOT" ]; then
    SITES_DIR="${PROJECT_ROOT}/data/sites"
    CLIENTS_COMPOSE_FILE="${PROJECT_ROOT}/clients/docker-compose-clients.yml"
else
    SITES_DIR="/data/sites"
    CLIENTS_COMPOSE_FILE="/clients/docker-compose-clients.yml"
fi

# --- Validace argumentu ---
if [ $# -lt 1 ]; then
    echo "Použití: $0 <site_name>" >&2
    echo "Příklad: $0 web1" >&2
    exit 1
fi

SITE_NAME="$1"

# Striktní regex validace názvu: pouze malá písmena a čísla začínající 'web' (např. web1, webblog)
if ! [[ "$SITE_NAME" =~ ^web[0-9a-z]{1,24}$ ]]; then
    echo "CHYBA: Neplatný název webu '${SITE_NAME}'. Musí začínat 'web' a obsahovat pouze malá písmena a číslice (např. web1, web2)." >&2
    exit 1
fi

echo "======================================================"
echo "  Zahájení Provisioningu: ${SITE_NAME}"
echo "======================================================"

SITE_DIR="${SITES_DIR}/${SITE_NAME}"
WP_IMAGE="${WP_IMAGE:-wordpress:6.7-php8.3-apache}"

# Kontrola, zda web již neexistuje
if [ -d "$SITE_DIR" ]; then
    echo "CHYBA: Adresář ${SITE_DIR} již existuje. Web '${SITE_NAME}' již pravděpodobně běží." >&2
    exit 1
fi

# --- 1. Generování náhodných údajů (odolné vůči SIGPIPE / Broken pipe pod pipefail) ---
generate_random_string() {
    local length="$1"
    local allowed="$2"
    local result=""
    while [ "${#result}" -lt "$length" ]; do
        local chunk
        chunk=$(head -c 256 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc "$allowed" 2>/dev/null || true)
        result="${result}${chunk}"
    done
    printf "%s" "${result:0:length}"
}

RANDOM_SUFFIX=$(generate_random_string 6 "a-z0-9")
DB_NAME="wp_${SITE_NAME}_${RANDOM_SUFFIX}"
DB_USER="${SITE_NAME}_${RANDOM_SUFFIX}"
DB_PASS="Wp9#"$(generate_random_string 20 "A-Za-z0-9!#%*")

# Náhodné salts pro wp-config.php
generate_salt() {
    generate_random_string 64 'A-Za-z0-9!#$%&*+,-./:;<=>?@^_~'
}
AUTH_KEY=$(generate_salt)
SECURE_AUTH_KEY=$(generate_salt)
LOGGED_IN_KEY=$(generate_salt)
NONCE_KEY=$(generate_salt)
AUTH_SALT=$(generate_salt)
SECURE_AUTH_SALT=$(generate_salt)
LOGGED_IN_SALT=$(generate_salt)
NONCE_SALT=$(generate_salt)

echo "[1/6] Vygenerována databáze: ${DB_NAME}, uživatel: ${DB_USER}"

# --- 2. Vytvoření DB a uživatele v MySQL Master ---
echo "[2/6] Připojování k MySQL Master (${MYSQL_HOST}:${MYSQL_PORT:-3306})..."

# Detekce mariadb vs mysql klienta a ignorování self-signed certifikátu v ProxySQL
if command -v mariadb &>/dev/null; then
    MYSQL_BIN="mariadb --skip-ssl-verify-server-cert"
elif mysql --help 2>/dev/null | grep -q "ssl-mode"; then
    MYSQL_BIN="mysql --ssl-mode=REQUIRED"
else
    MYSQL_BIN="mysql --skip-ssl-verify-server-cert"
fi

MYSQL_CMD="${MYSQL_BIN} -h ${MYSQL_HOST} -P ${MYSQL_PORT:-3306} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} --default-character-set=utf8mb4"

# SQL příkazy pro vytvoření izolované DB a uživatele s omezenými právy pouze k jeho DB
SQL_CREATE_DB_AND_USER="
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
"

if echo "$SQL_CREATE_DB_AND_USER" | $MYSQL_CMD; then
    echo "  ✓ Databáze i uživatel byli v MySQL Masteru úspěšně vytvořeni."
else
    echo "CHYBA: Nepodařilo se vytvořit databázi nebo uživatele v MySQL Master!" >&2
    exit 1
fi

# Pokud se připojujeme přes ProxySQL (port 6033), zaregistrujeme nového uživatele i do ProxySQL Admina (port 6032)
PROXYSQL_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
PROXYSQL_ADMIN_USER="${PROXYSQL_ADMIN_USER:-admin}"
PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

if [ "${MYSQL_PORT:-3306}" = "6033" ] || [ -n "${PROXYSQL_ADMIN_PORT:-}" ]; then
    echo "  Registrace uživatele '${DB_USER}' do ProxySQL (${MYSQL_HOST}:${PROXYSQL_PORT})..."
    PROXY_ERR=""
    PROXY_CMD="mariadb -h ${MYSQL_HOST} -P ${PROXYSQL_PORT} -u ${PROXYSQL_ADMIN_USER} -p${PROXYSQL_ADMIN_PASS} --skip-ssl"
    if ! command -v mariadb &>/dev/null; then
        PROXY_CMD="mysql -h ${MYSQL_HOST} -P ${PROXYSQL_PORT} -u ${PROXYSQL_ADMIN_USER} -p${PROXYSQL_ADMIN_PASS} --skip-ssl"
    fi

    if PROXY_ERR=$($PROXY_CMD -e "INSERT OR REPLACE INTO mysql_users(username, password, default_hostgroup, transaction_persistent) VALUES ('${DB_USER}', '${DB_PASS}', 10, 1); LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;" 2>&1); then
        echo "  ✓ Uživatel '${DB_USER}' úspěšně zaregistrován v ProxySQL."
    else
        echo "  ℹ Upozornění: Automatický zápis do ProxySQL (port ${PROXYSQL_PORT}) neprošel:"
        echo "    $PROXY_ERR"
    fi
fi

# --- 3. Příprava lokálních souborů a volume ---
echo "[3/6] Příprava konfiguračních souborů v ${SITE_DIR}..."

# Ověření oprávnění k zápisu
if [ ! -d "$SITES_DIR" ]; then
    mkdir -p "$SITES_DIR" 2>/dev/null || true
fi
if [ ! -w "$SITES_DIR" ]; then
    echo "CHYBA: Adresář '${SITES_DIR}' není zapisovatelný pro uživatele '$(whoami)'." >&2
    echo "Na hostitelském serveru prosím spusťte: sudo chmod -R 777 ${PROJECT_ROOT:-/opt/own_hosting}/data" >&2
    exit 1
fi
mkdir -p "$SITE_DIR"

# A) Soubor db.env (čtený WordPress kontejnerem z volume)
cat > "${SITE_DIR}/db.env" << EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}
DB_HOST=${MYSQL_HOST}
DB_PORT=${MYSQL_PORT:-3306}
SITE_NAME=${SITE_NAME}
EOF
chmod 644 "${SITE_DIR}/db.env"

# B) Vlastní wp-config.php s dynamickým načítáním db.env a sub-path routingem
cat > "${SITE_DIR}/wp-config.php" << 'EOF'
<?php
/**
 * WordPress Konfigurace pro Home-lab Webhosting s podporou sub-path (/web1, /web2)
 */

// Načtení přihlašovacích údajů z připojeného db.env souboru
$creds_file = file_exists('/etc/wordpress/db.env') ? '/etc/wordpress/db.env' : (__DIR__ . '/db.env');
$creds = file_exists($creds_file) ? parse_ini_file($creds_file) : [];

define('DB_NAME',     $creds['DB_NAME']     ?? getenv('WORDPRESS_DB_NAME')     ?? 'wordpress');
define('DB_USER',     $creds['DB_USER']     ?? getenv('WORDPRESS_DB_USER')     ?? 'wordpress');
define('DB_PASSWORD', $creds['DB_PASSWORD'] ?? getenv('WORDPRESS_DB_PASSWORD') ?? '');

$db_host = $creds['DB_HOST'] ?? getenv('WORDPRESS_DB_HOST') ?? '127.0.0.1';
$db_port = $creds['DB_PORT'] ?? getenv('WORDPRESS_DB_PORT') ?? '';
if (!empty($db_port) && $db_port != '3306' && strpos($db_host, ':') === false) {
    $db_host .= ':' . $db_port;
}
define('DB_HOST',     $db_host);
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

$site_name = $creds['SITE_NAME'] ?? basename(__DIR__);

// Detekce protokolu z reverzní proxy
$proto = 'http';
if ((isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') ||
    (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on')) {
    $proto = 'https';
    $_SERVER['HTTPS'] = 'on';
}

$http_host = $_SERVER['HTTP_X_FORWARDED_HOST'] ?? $_SERVER['HTTP_HOST'] ?? 'localhost';

// Dynamické nastavení WP_HOME a WP_SITEURL na sub-path (/web1, /web2 apod.)
define('WP_HOME',    $proto . '://' . $http_host . '/' . $site_name);
define('WP_SITEURL', $proto . '://' . $http_host . '/' . $site_name);

// Zajištění existence symlinku /var/www/html/<site_name> -> . pro obsluhu sub-path URL
if (!empty($site_name) && !file_exists(__DIR__ . '/' . $site_name)) {
    @symlink('.', __DIR__ . '/' . $site_name);
}

// Bezpečnostní klíče a soli
EOF

cat >> "${SITE_DIR}/wp-config.php" << EOF
define('AUTH_KEY',         '${AUTH_KEY}');
define('SECURE_AUTH_KEY',  '${SECURE_AUTH_KEY}');
define('LOGGED_IN_KEY',    '${LOGGED_IN_KEY}');
define('NONCE_KEY',        '${NONCE_KEY}');
define('AUTH_SALT',        '${AUTH_SALT}');
define('SECURE_AUTH_SALT', '${SECURE_AUTH_SALT}');
define('LOGGED_IN_SALT',   '${LOGGED_IN_SALT}');
define('NONCE_SALT',       '${NONCE_SALT}');
EOF

cat >> "${SITE_DIR}/wp-config.php" << 'EOF'

$table_prefix = 'wp_';
define('WP_DEBUG', false);

// Přímé stahování pluginů/šablon bez FTP dotazu
define('FS_METHOD', 'direct');

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
EOF
chmod 644 "${SITE_DIR}/wp-config.php"

# C) Soubor .htaccess s RewriteBase pro daný sub-path
cat > "${SITE_DIR}/.htaccess" << EOF
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /${SITE_NAME}/
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /${SITE_NAME}/index.php [L]
</IfModule>
# END WordPress
EOF
chmod 644 "${SITE_DIR}/.htaccess"

# --- 4. Aktualizace docker-compose-clients.yml ---
echo "[4/6] Aktualizace ${CLIENTS_COMPOSE_FILE}..."

if [ ! -f "$CLIENTS_COMPOSE_FILE" ]; then
    echo "CHYBA: Soubor ${CLIENTS_COMPOSE_FILE} neexistuje!" >&2
    exit 1
fi

# Příprava bloku služby pro nový WordPress kontejner
NEW_SERVICE_BLOCK="  # --- SITE: ${SITE_NAME} ---
  ${SITE_NAME}-wordpress:
    image: ${WP_IMAGE}
    container_name: ${SITE_NAME}-wordpress
    restart: unless-stopped
    volumes:
      - wordpress-${SITE_NAME}-data:/var/www/html
      - ../data/sites/${SITE_NAME}/db.env:/etc/wordpress/db.env:ro
      - ../data/sites/${SITE_NAME}/wp-config.php:/var/www/html/wp-config.php
      - ../data/sites/${SITE_NAME}/.htaccess:/var/www/html/.htaccess
    networks:
      - webhosting-network
  # --- END: ${SITE_NAME} ---"

NEW_VOLUME_BLOCK="  # --- VOL: ${SITE_NAME} ---
  wordpress-${SITE_NAME}-data:
  # --- ENDVOL: ${SITE_NAME} ---"

# Vložení služby a volume do compose souboru bezpečně přes /tmp
TMP_FILE=$(mktemp /tmp/compose.XXXXXX 2>/dev/null || mktemp)

# Vložení služby před značku # --- SITES_END ---
if ! awk -v block="$NEW_SERVICE_BLOCK" '
/# --- SITES_END ---/ { print block }
{ print }
' "$CLIENTS_COMPOSE_FILE" > "$TMP_FILE"; then
    echo "CHYBA: Nepodařilo se zapsat novou službu do dočasného souboru!" >&2
    rm -f "$TMP_FILE"
    exit 1
fi
cat "$TMP_FILE" > "$CLIENTS_COMPOSE_FILE"

# Vložení volume před značku # --- VOLUMES_END ---
if ! awk -v block="$NEW_VOLUME_BLOCK" '
/# --- VOLUMES_END ---/ { print block }
{ print }
' "$CLIENTS_COMPOSE_FILE" > "$TMP_FILE"; then
    echo "CHYBA: Nepodařilo se zapsat volume do dočasného souboru!" >&2
    rm -f "$TMP_FILE"
    exit 1
fi
cat "$TMP_FILE" > "$CLIENTS_COMPOSE_FILE"
rm -f "$TMP_FILE"

echo "  ✓ ${CLIENTS_COMPOSE_FILE} byl úspěšně aktualizován."

# --- 5. Spuštění kontejneru přes Docker Compose ---
echo "[5/6] Spouštění WordPress kontejneru..."

# Detekce kontejnerového enginu (Docker nebo Podman)
if command -v docker &>/dev/null; then
    ENGINE="docker"
elif command -v podman &>/dev/null; then
    ENGINE="podman"
else
    echo "CHYBA: V systému nebyl nalezen ani 'docker' ani 'podman'!" >&2
    exit 1
fi

# Zjištění, zda potřebujeme sudo pro komunikaci se socketem
if [ "$(id -u)" -eq 0 ]; then
    RUN_CMD="${ENGINE}"
elif ${ENGINE} ps &>/dev/null; then
    RUN_CMD="${ENGINE}"
elif command -v sudo &>/dev/null && sudo -n ${ENGINE} ps &>/dev/null; then
    RUN_CMD="sudo ${ENGINE}"
elif [ "$ENGINE" = "podman" ]; then
    RUN_CMD="podman"
else
    # Pokud sudo -n selže (vyžaduje heslo), nesmíme volat sudo v neinteraktivním skriptu.
    # Spustíme přímo ENGINE bez sudo.
    RUN_CMD="${ENGINE}"
fi

# Diagnostická kontrola přístupu k socketu
if ! $RUN_CMD ps &>/dev/null; then
    echo "  ⚠ Upozornění: Příkaz '${RUN_CMD} ps' selhal." >&2
    if [ -e /var/run/docker.sock ]; then
        echo "    Socket /var/run/docker.sock existuje, ale uživatel '$(whoami)' nemá oprávnění k zápisu." >&2
        echo "    Rychlá náprava na serveru: sudo chmod 666 /var/run/docker.sock" >&2
    fi
fi

# Zajištění existence sdílené sítě
$RUN_CMD network create webhosting-network 2>/dev/null || true

# Spuštění konkrétní služby přes compose s odchycením chybového výstupu
COMPOSE_OUT=""
if COMPOSE_OUT=$($RUN_CMD compose -f "$CLIENTS_COMPOSE_FILE" up -d "${SITE_NAME}-wordpress" 2>&1); then
    echo "  ✓ Kontejner ${SITE_NAME}-wordpress byl spuštěn (přes ${ENGINE} compose)."
elif command -v docker-compose &>/dev/null && COMPOSE_OUT=$($RUN_CMD-compose -f "$CLIENTS_COMPOSE_FILE" up -d "${SITE_NAME}-wordpress" 2>&1 || docker-compose -f "$CLIENTS_COMPOSE_FILE" up -d "${SITE_NAME}-wordpress" 2>&1); then
    echo "  ✓ Kontejner ${SITE_NAME}-wordpress byl spuštěn (přes docker-compose)."
elif command -v podman-compose &>/dev/null && COMPOSE_OUT=$(podman-compose -f "$CLIENTS_COMPOSE_FILE" up -d "${SITE_NAME}-wordpress" 2>&1); then
    echo "  ✓ Kontejner ${SITE_NAME}-wordpress byl spuštěn (přes podman-compose)."
else
    echo "CHYBA: Nepodařilo se spustit kontejner přes Compose (${ENGINE})!" >&2
    if [ -n "$COMPOSE_OUT" ]; then
        echo "Výstup Compose:" >&2
        echo "$COMPOSE_OUT" >&2
    fi
    exit 1
fi

# --- 6. Finální inicializace symlinku a kontrola ---
echo "[6/6] Inicializace WordPress prostředí a symlinku..."
sleep 3
# Vytvoření symlinku /var/www/html/<site_name> -> . přímo v kontejneru
$RUN_CMD exec "${SITE_NAME}-wordpress" ln -sfn . "/var/www/html/${SITE_NAME}" 2>/dev/null || true

# Zápis do logu
LOGS_DIR="${PROJECT_ROOT}/data/logs"
mkdir -p "$LOGS_DIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROVISIONED: site=${SITE_NAME} db=${DB_NAME} user=${DB_USER} by=$(whoami)" >> "${LOGS_DIR}/provision.log"

echo ""
echo "======================================================"
echo "  ✓ Webhosting '${SITE_NAME}' úspěšně vytvořen!"
echo "======================================================"
echo "URL adresa:   http://${SERVER_IP:-127.0.0.1}:${ADMIN_PORT:-8080}/${SITE_NAME}/"
echo "Admin panel:  http://${SERVER_IP:-127.0.0.1}:${ADMIN_PORT:-8080}/${SITE_NAME}/wp-admin/"
echo "MySQL DB:     ${DB_NAME}"
echo "MySQL User:   ${DB_USER}"
echo "Kontejner:    ${SITE_NAME}-wordpress"
echo "======================================================"

exit 0

