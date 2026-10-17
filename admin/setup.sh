#!/usr/bin/env bash
# ==============================================================================
# Automatický inicializační a spouštěcí skript (Setup & Run)
# ==============================================================================
# Tento skript si sám dynamicky zjistí cestu k projektu, ať už leží v:
# /opt/own_hosting, /home/user/own_hosting nebo kdekoli jinde.
#
# Co udělá:
# 1. Zjistí přesnou absolutní cestu k projektu ($PROJECT_ROOT).
# 2. Nastaví spustitelná práva (chmod +x) pro všechny skripty.
# 3. Vygeneruje /etc/sudoers.d/webhosting-manager s dynamickou cestou.
# 4. Vytvoří sdílenou síť 'webhosting-network' (v Podmanu nebo Dockeru).
# 5. Spustí Nginx + PHP-FPM administrační stack.
# ==============================================================================

set -euo pipefail

# Dynamická detekce cesty bez nutnosti cokoli ručně konfigurovat
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "======================================================"
echo "  Webhosting Manager - Automatický Start & Setup"
echo "======================================================"
echo "Detekovaná cesta projektu: ${PROJECT_ROOT}"

# 1. Detekce kontejnerového enginu (Podman vs Docker)
if command -v podman &>/dev/null; then
    ENGINE="podman"
elif command -v docker &>/dev/null; then
    ENGINE="docker"
else
    echo "CHYBA: V systému nebyl nalezen 'podman' ani 'docker'!" >&2
    exit 1
fi
echo "Detekovaný kontejnerový engine: ${ENGINE}"

# 2. Kontrola .env souboru (oprava pokud byl vytvořen Dockerem/Podmanem jako adresář)
if [ -d "${PROJECT_ROOT}/.env" ]; then
    echo "  Oprava: ${PROJECT_ROOT}/.env byl vytvořen jako adresář. Nahrazuji souborem z .env.example..."
    rm -rf "${PROJECT_ROOT}/.env"
    cp "${PROJECT_ROOT}/.env.example" "${PROJECT_ROOT}/.env"
elif [ ! -f "${PROJECT_ROOT}/.env" ] && [ -f "${PROJECT_ROOT}/.env.example" ]; then
    echo "  Vytváření .env z .env.example..."
    cp "${PROJECT_ROOT}/.env.example" "${PROJECT_ROOT}/.env"
fi

# 3. Nastavení spustitelných práv pro skripty
echo "[1/4] Nastavování práv pro skripty..."
chmod +x "${PROJECT_ROOT}/scripts/"*.sh 2>/dev/null || true
chmod +x "${PROJECT_ROOT}/admin/nginx/"*.sh 2>/dev/null || true

# Nastavení zápisových práv pro data a clients (aby kontejner mohl vytvářet weby)
mkdir -p "${PROJECT_ROOT}/data/sites" "${PROJECT_ROOT}/data/logs"
chmod -R 777 "${PROJECT_ROOT}/data" 2>/dev/null || true
chmod -R 777 "${PROJECT_ROOT}/clients" 2>/dev/null || true
chmod 666 "${PROJECT_ROOT}/clients/docker-compose-clients.yml" 2>/dev/null || true
[ -e /var/run/docker.sock ] && (chmod 666 /var/run/docker.sock 2>/dev/null || sudo chmod 666 /var/run/docker.sock 2>/dev/null || true)

# 3. Instalace sudoers s dynamicky vygenerovanou cestou (pokud máme root/sudo)
echo "[2/4] Konfigurace sudoers..."
SUDOERS_FILE="/etc/sudoers.d/webhosting-manager"

generate_sudoers() {
    cat << EOF
# Automaticky vygenerováno pro projekt v: ${PROJECT_ROOT}
script-deploy ALL=(root) NOPASSWD: /usr/bin/docker compose *, /usr/local/bin/docker compose *, /usr/bin/docker-compose *, /usr/local/bin/docker-compose *, /usr/bin/docker *, /usr/local/bin/docker *
script-deploy ALL=(root) NOPASSWD: /usr/bin/podman compose *, /usr/local/bin/podman compose *, /usr/bin/podman-compose *, /usr/local/bin/podman *
www-data ALL=(script-deploy) NOPASSWD: ${PROJECT_ROOT}/scripts/provision.sh *
www-data ALL=(script-deploy) NOPASSWD: ${PROJECT_ROOT}/scripts/deprovision.sh *
EOF
}

if [ "$(id -u)" -eq 0 ]; then
    generate_sudoers > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    echo "  ✓ Sudoers úspěšně nakonfigurován s cestou ${PROJECT_ROOT}"
elif sudo -n true 2>/dev/null; then
    generate_sudoers | sudo tee "$SUDOERS_FILE" >/dev/null
    sudo chmod 0440 "$SUDOERS_FILE"
    echo "  ✓ Sudoers úspěšně nakonfigurován přes sudo s cestou ${PROJECT_ROOT}"
else
    echo "  ⚠ Spuštěno bez roota: sudoers můžete nastavit ručně ze souboru ${PROJECT_ROOT}/sudoers-script-deploy"
fi

# 4. Zajištění existence sdílené sítě
echo "[3/4] Kontrola sítě 'webhosting-network'..."
if [ "$ENGINE" = "podman" ]; then
    podman network exists webhosting-network 2>/dev/null || podman network create webhosting-network 2>/dev/null || true
    # Pokud běží systémový podman socket, zapneme jej
    if [ "$(id -u)" -eq 0 ] && systemctl list-unit-files | grep -q "podman.socket"; then
        systemctl enable --now podman.socket 2>/dev/null || true
    fi
else
    docker network inspect webhosting-network &>/dev/null || docker network create webhosting-network 2>/dev/null || true
fi

# 5. Spuštění Administračního kontejneru přes Compose
echo "[4/4] Spouštění Administračního panelu (${ENGINE} compose)..."
ADMIN_COMPOSE="${PROJECT_ROOT}/admin/docker-compose-admin.yml"

if [ "$ENGINE" = "podman" ]; then
    if podman compose version &>/dev/null; then
        podman compose -f "$ADMIN_COMPOSE" up -d --build
    elif command -v podman-compose &>/dev/null; then
        podman-compose -f "$ADMIN_COMPOSE" up -d
    elif command -v docker-compose &>/dev/null; then
        docker-compose -f "$ADMIN_COMPOSE" up -d --build
    else
        echo "Varování: podman compose nebyl nalezen, pokus o standardní spuštění..."
        podman compose -f "$ADMIN_COMPOSE" up -d --build
    fi
else
    docker compose -f "$ADMIN_COMPOSE" up -d --build
fi

echo ""
echo "======================================================"
echo "  ✓ Administrační stack byl úspěšně spuštěn!"
echo "======================================================"
echo "Cesta projektu: ${PROJECT_ROOT}"
echo "Admin web běží na: http://localhost:8080/ (nebo na IP vašeho serveru)"
echo "======================================================"

