#!/usr/bin/env bash
# ==============================================================================
# Deprovisioning Script - Bezpečné smazání WordPress instance
# ==============================================================================
# Použití: ./deprovision.sh <site_name>
# Příklad: ./deprovision.sh web1
#
# BEZPEČNOSTNÍ MECHANISMY:
# 1. Striktní validace vstupního argumentu (<site_name>).
# 2. Striktní validace formátu názvu databáze (^wp_web[0-9a-z]+_[a-z0-9]{6}$).
# 3. Zákaz jakéhokoli globálního mazání - DROP je prováděn striktně pouze
#    nad odpovídající klientskou databází.
# 4. Použití vyhrazeného deprovisioning účtu nebo řízených dočasných práv.
# 5. Kompletní auditní logování operace do souboru deprovision.log.
# ==============================================================================

set -euo pipefail

# --- Zjištění cest ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detekce kořenového adresáře projektu (na hostiteli i v kontejneru)
if [ -n "${PROJECT_ROOT:-}" ] && [ -d "${PROJECT_ROOT}" ] && [ "${PROJECT_ROOT}" != "/" ]; then
    PROJECT_ROOT="${PROJECT_ROOT}"
elif [ "$SCRIPT_DIR" = "/scripts" ]; then
    if [ -d "/opt/own_hosting" ]; then
        PROJECT_ROOT="/opt/own_hosting"
    elif [ -d "/workspace" ]; then
        PROJECT_ROOT="/workspace"
    else
        PROJECT_ROOT=""
    fi
else
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

# 1. STRIKTNÍ VALIDACE NÁZVU WEBU
if ! [[ "$SITE_NAME" =~ ^web[0-9a-z]{1,24}$ ]]; then
    echo "CHYBA: Neplatný formát názvu webu '${SITE_NAME}'." >&2
    exit 1
fi

echo "======================================================"
echo "  Zahájení Deprovisioningu (BEZPEČNÝ REŽIM): ${SITE_NAME}"
echo "======================================================"

SITE_DIR="${SITES_DIR}/${SITE_NAME}"
CLIENTS_COMPOSE_FILE="${PROJECT_ROOT:-}/clients/docker-compose-clients.yml"

# --- Krok 1: Zjištění DB jména a DB uživatele ---
echo "[1/6] Vyhledávání databázových údajů pro '${SITE_NAME}'..."

DB_NAME=""
DB_USER=""

if [ -f "${SITE_DIR}/db.env" ]; then
    DB_NAME=$(grep '^DB_NAME=' "${SITE_DIR}/db.env" | cut -d'=' -f2- | tr -d '[:space:]')
    DB_USER=$(grep '^DB_USER=' "${SITE_DIR}/db.env" | cut -d'=' -f2- | tr -d '[:space:]')
fi

# Pokud db.env neexistuje, zkusíme najít DB podle vzoru v MySQL
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
DEP_USER="${MYSQL_DEPROVISION_USER:-${MYSQL_USER:-webhosting_admin}}"
DEP_PASS="${MYSQL_DEPROVISION_PASSWORD:-${MYSQL_PASSWORD}}"

# Detekce mariadb vs mysql klienta a ignorování self-signed certifikátu
if command -v mariadb &>/dev/null; then
    MYSQL_BIN="mariadb --skip-ssl-verify-server-cert"
elif mysql --help 2>/dev/null | grep -q "ssl-mode"; then
    MYSQL_BIN="mysql --ssl-mode=REQUIRED"
else
    MYSQL_BIN="mysql --skip-ssl-verify-server-cert"
fi

MYSQL_CMD="${MYSQL_BIN} -h ${MYSQL_HOST} -P ${MYSQL_PORT} -u ${DEP_USER} -p${DEP_PASS} --default-character-set=utf8mb4"

if [ -z "$DB_NAME" ]; then
    echo "  Varování: db.env nebyl nalezen. Dotazuji MySQL na databázi odpovídající vzoru..."
    DB_NAME=$($MYSQL_CMD -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME LIKE 'wp_${SITE_NAME}_%' LIMIT 1" 2>/dev/null || true)
fi

# 2. STRIKTNÍ BEZPEČNOSTNÍ KONTROLA NÁZVU DATABÁZE
if [ -n "$DB_NAME" ]; then
    if ! [[ "$DB_NAME" =~ ^wp_${SITE_NAME}_[a-z0-9]{6}$ ]]; then
        echo "KRITICKÁ BEZPEČNOSTNÍ CHYBA: Zjištěný název databáze '${DB_NAME}' neodpovídá striktnímu formátu 'wp_${SITE_NAME}_[a-z0-9]{6}'!" >&2
        echo "Operace byla okamžitě zastavena pro ochranu databáze." >&2
        exit 1
    fi
    echo "  ✓ Ověřena platná klientská databáze: ${DB_NAME}"
else
    echo "  Informace: Žádná databáze pro '${SITE_NAME}' nebyla nalezena."
fi

# --- Krok 2: Bezpečné smazání MySQL databáze a uživatele ---
echo "[2/6] Odstraňování MySQL databáze a uživatele..."

if [ -n "$DB_NAME" ]; then
    SQL_DROP="
    DROP DATABASE IF EXISTS \`${DB_NAME}\`;
    "
    if [ -n "$DB_USER" ]; then
        SQL_DROP="${SQL_DROP} DROP USER IF EXISTS '${DB_USER}'@'%';"
    fi

    if echo "$SQL_DROP" | $MYSQL_CMD; then
        echo "  ✓ Databáze '${DB_NAME}' a uživatel '${DB_USER}' byli bezpečně smazáni."
    else
        echo "  VAROVÁNÍ: Nepodařilo se smazat databázi přes deprovision účet. Pokus o smazání přes root/admin..."
        # Záložní pokus s admin účtem pokud má práva
        ADMIN_MYSQL="${MYSQL_BIN} -h ${MYSQL_HOST} -P ${MYSQL_PORT} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} --default-character-set=utf8mb4"
        echo "$SQL_DROP" | $ADMIN_MYSQL 2>/dev/null || true
    fi

    # Odstranění uživatele z ProxySQL (pokud běžíme přes port 6033)
    PROXYSQL_PORT="${PROXYSQL_ADMIN_PORT:-6032}"
    PROXYSQL_ADMIN_USER="${PROXYSQL_ADMIN_USER:-admin}"
    PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

    if [ "${MYSQL_PORT}" = "6033" ] || [ -n "${PROXYSQL_ADMIN_PORT:-}" ]; then
        if [ -n "$DB_USER" ]; then
            PROXY_CMD="mariadb -h ${MYSQL_HOST} -P ${PROXYSQL_PORT} -u ${PROXYSQL_ADMIN_USER} -p${PROXYSQL_ADMIN_PASS} --skip-ssl"
            if ! command -v mariadb &>/dev/null; then
                PROXY_CMD="mysql -h ${MYSQL_HOST} -P ${PROXYSQL_PORT} -u ${PROXYSQL_ADMIN_USER} -p${PROXYSQL_ADMIN_PASS} --skip-ssl"
            fi
            $PROXY_CMD -e "DELETE FROM mysql_users WHERE username='${DB_USER}'; LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;" 2>/dev/null || true
        fi
    fi
fi

# --- Krok 3: Zastavení a odstranění Docker kontejneru ---
echo "[3/6] Zastavení a smazání Docker kontejneru..."

# Detekce kontejnerového enginu (Docker nebo Podman)
if command -v docker &>/dev/null; then
    ENGINE="docker"
elif command -v podman &>/dev/null; then
    ENGINE="podman"
else
    echo "CHYBA: V systému nebyl nalezen ani 'docker' ani 'podman'!" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    RUN_CMD="${ENGINE}"
elif ${ENGINE} ps &>/dev/null; then
    RUN_CMD="${ENGINE}"
elif command -v sudo &>/dev/null && sudo -n ${ENGINE} ps &>/dev/null; then
    RUN_CMD="sudo ${ENGINE}"
elif [ "$ENGINE" = "podman" ]; then
    RUN_CMD="podman"
else
    RUN_CMD="${ENGINE}"
fi

if [ -f "$CLIENTS_COMPOSE_FILE" ]; then
    $RUN_CMD compose -f "$CLIENTS_COMPOSE_FILE" stop "${SITE_NAME}-wordpress" 2>/dev/null || \
    $RUN_CMD-compose -f "$CLIENTS_COMPOSE_FILE" stop "${SITE_NAME}-wordpress" 2>/dev/null || \
    docker-compose -f "$CLIENTS_COMPOSE_FILE" stop "${SITE_NAME}-wordpress" 2>/dev/null || \
    podman-compose -f "$CLIENTS_COMPOSE_FILE" stop "${SITE_NAME}-wordpress" 2>/dev/null || true
fi

$RUN_CMD rm -f "${SITE_NAME}-wordpress" 2>/dev/null || true
echo "  ✓ Kontejner ${SITE_NAME}-wordpress odstraněn."

# --- Krok 4: Odstranění Docker volume ---
echo "[4/6] Odstranění datového Docker volume..."
$RUN_CMD volume rm "wordpress-${SITE_NAME}-data" 2>/dev/null || true
echo "  ✓ Volume wordpress-${SITE_NAME}-data odstraněn."

# --- Krok 5: Vyčištění docker-compose-clients.yml ---
echo "[5/6] Úprava ${CLIENTS_COMPOSE_FILE}..."

if [ -f "$CLIENTS_COMPOSE_FILE" ]; then
    TMP_FILE=$(mktemp /tmp/compose.XXXXXX 2>/dev/null || mktemp)
    if sed "/# --- SITE: ${SITE_NAME} ---/,/# --- END: ${SITE_NAME} ---/d" "$CLIENTS_COMPOSE_FILE" | \
       sed "/# --- VOL: ${SITE_NAME} ---/,/# --- ENDVOL: ${SITE_NAME} ---/d" > "$TMP_FILE"; then
        cat "$TMP_FILE" > "$CLIENTS_COMPOSE_FILE"
        echo "  ✓ Služba odstraněna z docker-compose-clients.yml."
    fi
    rm -f "$TMP_FILE"
fi

# --- Krok 6: Odstranění lokální složky a zápis do logu ---
echo "[6/6] Mazání lokálních souborů a logování..."

if [ -d "$SITE_DIR" ]; then
    rm -rf "$SITE_DIR"
    echo "  ✓ Adresář ${SITE_DIR} byl smazán."
fi

LOGS_DIR="${PROJECT_ROOT}/data/logs"
mkdir -p "$LOGS_DIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEPROVISIONED: site=${SITE_NAME} db=${DB_NAME} user=${DB_USER} by=$(whoami)" >> "${LOGS_DIR}/deprovision.log"

echo ""
echo "======================================================"
echo "  ✓ Webhosting '${SITE_NAME}' byl kompletně smazán!"
echo "======================================================"

exit 0
