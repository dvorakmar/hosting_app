# 🚀 Automatizovaný WordPress Webhosting Manager (Home-Lab)

Kompletní řešení pro automatizovaný provisioning a správu WordPress webhostingů na jedné sdílené IP adrese s využitím existujícího MySQL clusteru (Master / ProxySQL), Docker Compose a Nginx Reverse Proxy.

---

> [!IMPORTANT]
> ### ⚡ DŮLEŽITÉ: Nastavení oprávnění & Rootless Podman (Bezpečný provoz)
> Pro maximální bezpečnost provozujte systém v **Rootless Podmanu** (kontejnery běží bez jakýchkoliv root práv na hostitelském serveru):
>
> **1. Aktivace Rootless Podman socketu (na hostiteli):**
> ```bash
> systemctl --user enable --now podman.socket
> loginctl enable-linger $USER
> ```
> *Tento příkaz vytvoří bezpečný uživatelský socket v `/run/user/$(id -u)/podman/podman.sock`.*
>
> **2. Nastavení proměnné v `.env`:**
> ```bash
> # Do .env doplňte cestu k vašemu uživatelskému socketu:
> echo "DOCKER_SOCK=/run/user/$(id -u)/podman/podman.sock" >> /opt/own_hosting/.env
> ```
>
> **3. Běžná práva (není potřeba sudo, pokud jste vlastníkem složky):**
> ```bash
> chmod -R 775 /opt/own_hosting/data /opt/own_hosting/clients
> chmod 664 /opt/own_hosting/clients/docker-compose-clients.yml
> chmod +x /opt/own_hosting/scripts/*.sh /opt/own_hosting/admin/nginx/*.sh /opt/own_hosting/admin/*.sh
> ```
> *(Pokud spustíte náš skript `./admin/setup.sh`, detekuje Rootless Podman socket a nastaví vše automaticky).*

## 📐 1. Architektura systému

```
                         Uživatel / Prohlížeč
                                  │
         ┌────────────────────────┴────────────────────────┐
         │ http://SERVER_IP:8080/                          │ http://SERVER_IP:8080/web1/
         ▼                                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Nginx Reverse Proxy (webhosting-nginx)                                      │
│ - Port 8080:80                                                              │
│ - Docker resolver: 127.0.0.11                                               │
└───────────────────────┬─────────────────────────────────┬───────────────────┘
                        │ / (Admin Panel)                 │ /web1/, /web2/, ...
                        ▼                                 ▼
┌─────────────────────────────────────────┐   ┌───────────────────────────────┐
│ PHP-FPM Backend (webhosting-php-fpm)    │   │ Klientské WordPress Kontejnery│
│ - Správa zákazníků a webů               │   │ (docker-compose-clients.yml)  │
│ - Volání provision.sh a deprovision.sh  │   │ - web1-wordpress              │
└───────────────────────┬─────────────────┘   │ - web2-wordpress              │
                        │                     └───────────────┬───────────────┘
                        │                                     │
                        │ SQL dotazy                          │ SQL připojení
                        ▼                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ MySQL Cluster (Master / ProxySQL)                                           │
│ - Databáze: webhosting_admin_db (správa uživatelů a webů)                   │
│ - Databáze: wp_web1_xxxxxx (izolovaná DB pro web1)                          │
│ - Databáze: wp_web2_yyyyyy (izolovaná DB pro web2)                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📁 2. Struktura projektu

```
own_hosting/
├── .env                              # Hlavní konfigurace (MySQL, porty, IP)
├── sudoers-script-deploy             # Šablona pro /etc/sudoers.d/
├── README.md                         # Tato dokumentace
├── admin/                            # Administrační stack
│   ├── docker-compose-admin.yml      # Nginx + PHP-FPM
│   ├── nginx/
│   │   └── nginx.conf                # Reverzní proxy konfigurace (routing / a /webX/)
│   └── php/
│       └── Dockerfile                # PHP-FPM s pdo_mysql, mariadb-client a docker-cli
├── admin-web/                        # Zdrojové kódy klientského webu (PHP)
│   ├── index.php                     # Login + Klientský dashboard + Akce
│   ├── config.php                    # DB konfigurace a PDO připojení
│   ├── auth.php                      # Autentizace zákazníků
│   └── functions.php                 # Spouštění skriptů a manipulace s DB
├── clients/
│   └── docker-compose-clients.yml    # Dynamický compose soubor pro WordPress kontejnery
├── scripts/
│   ├── provision.sh                  # Skript pro vytvoření WordPressu a DB
│   └── deprovision.sh                # Zabezpečený skript pro smazání WordPressu a DB
└── data/
    ├── init-mysql.sql                # SQL inicializace uživatelů a tabulek
    ├── sites/                        # Složky klientských webů (db.env, wp-config, htaccess)
    └── logs/                         # Auditní logy operací (provision.log, deprovision.log)
```

---

## 🔐 3. Příprava MySQL Clusteru (Krok 1)

Na vašem **MySQL Masteru** spusťte inicializační skript `data/init-mysql.sql`.

Tento skript vytvoří:
1. **`webhosting_admin`**: Provozní uživatel pro zakládání webů. Má práva `CREATE DATABASE`, `CREATE USER` a plná práva na `wp_%` databáze (`WITH GRANT OPTION`). **NEMÁ globální `DROP`**, takže nemůže smazat systémové databáze.
2. **`deprovision_admin`**: Vyhrazený uživatel pro bezpečné mazání. Má právo `DROP` **výhradně** nad databázemi začínajícími na `wp_%`.
3. **`admin_user`** a databázi **`webhosting_admin_db`**: Databáze pro klientský administrační panel.

Spusťte na Masteru:
```bash
mysql -h 127.0.0.1 -u root -p < data/init-mysql.sql
```

Nezapomeňte upravit hesla v `.env` souboru podle vašich požadavků!

---

## 🛡️ 4. Bezpečnostní nastavení Sudoers (Krok 2)

Pro splnění principu nejnižších privilegií vytvořte na hostitelském serveru dedikovaného uživatele `script-deploy`:

```bash
# Vytvoření uživatele
sudo useradd -m -s /bin/bash script-deploy

# Zkopírování sudoers konfigurace
sudo cp sudoers-script-deploy /etc/sudoers.d/webhosting-manager
sudo chmod 0440 /etc/sudoers.d/webhosting-manager

# Kontrola syntaxe
sudo visudo -c
```

**Výsledek:** Uživatel `script-deploy` může spouštět **pouze** příkazy `docker compose` bez hesla.

---

## 🌐 5. Spuštění Administračního panelu (Krok 3)

Díky automatické detekci cest nemusíte v `.env` ani jinde ručně měnit cestu k projektu. Můžete si vybrat jeden ze způsobů spuštění:

### Možnost A: Přes automatický skript (Doporučeno - bez závislostí)
Tento skript si sám zjistí, kde projekt leží (např. `/opt/own_hosting` nebo kdekoli jinde), nastaví práva, nakonfiguruje sudoers a spustí kontejnery:
```bash
./admin/setup.sh
```

### Možnost B: Přes Ansible Playbook
Pokud používáte Ansible, stačí spustit:
```bash
ansible-playbook admin/playbook.yml
# nebo z kořene projektu:
ansible-playbook main.yml
```

### Možnost C: Standardní Compose
Nebo standardně ručně:
```bash
cd admin
docker compose -f docker-compose-admin.yml up -d --build
# (v Podmanu: podman compose -f docker-compose-admin.yml up -d --build)
```

Ověřte funkčnost:
- Webový panel: otevřete v prohlížeči `http://192.168.1.100:8080/` (nebo `http://localhost:8080/`).
- Přihlaste se výchozím demo účtem:
  - **Uživatel:** `demo`
  - **Heslo:** `demo123`

---

## ⚙️ 6. Jak funguje Provisioning (`provision.sh`)

Skript lze zavolat buď z webu kliknutím na **"Vytvořit web"**, nebo ručně z terminálu:

```bash
./scripts/provision.sh web1
```

**Co skript provede:**
1. **Validace názvu:** Ověří shodu s regexem `^web[0-9a-z]{1,24}$`.
2. **Generování DB údajů:** Vygeneruje 6místný náhodný řetězec (např. `k3m8p2`).
   - Název databáze: `wp_web1_k3m8p2`
   - Uživatel: `web1_k3m8p2`
   - Bezpečné náhodné heslo (24 znaků)
3. **MySQL Master:** Připojí se a vytvoří izolovanou DB a uživatele s oprávněními výhradně k této DB.
4. **Volume a konfigurace (`data/sites/web1/`):**
   - `db.env`: Přihlašovací údaje do DB.
   - `wp-config.php`: Vlastní konfigurace načítající `db.env` přes `parse_ini_file()`, dynamicky nastavující `WP_HOME` a `WP_SITEURL` na `http://IP:PORT/web1/` a vytvářející symlink pro sub-path.
   - `.htaccess`: Nastavení Apache `RewriteBase /web1/`.
5. **Docker Compose:** Přidá kontejner `web1-wordpress` a volume do `clients/docker-compose-clients.yml`.
6. **Spuštění:** Spustí kontejner a připojí jej do sdílené sítě `webhosting-network`.

---

## 🗑️ 7. Bezpečný Deprovisioning (`deprovision.sh`)

Skript lze zavolat z webu kliknutím na tlačítko **"Smazat"**, nebo z terminálu:

```bash
./scripts/deprovision.sh web1
```

**Bezpečnostní garance:**
1. Striktní validace argumentu.
2. Zjištění názvu databáze z `data/sites/web1/db.env` nebo schématu.
3. **Kritická validace:** Název databáze MUSÍ přesně odpovídat `^wp_web[0-9a-z]+_[a-z0-9]{6}$`. Pokud by došlo k pokusu o podvržení systémové databáze, skript okamžitě skončí chybou.
4. Smazání DB a uživatele přes účet `deprovision_admin`.
5. Zastavení a smazání kontejneru a volume `wordpress-web1-data`.
6. Odstranění definice z `docker-compose-clients.yml`.
7. Smazání lokální složky a auditní zápis do `data/logs/deprovision.log`.

---

## 💡 8. Jak je vyřešen Sub-path Routing (`/web1`, `/web2`)

WordPress standardně předpokládá běh v kořeni domény. Zde je problém vyřešen trojkombinací:

1. **Nginx Reverse Proxy (`admin/nginx/nginx.conf`):**
   - Zachytává `^/(?<site>web[0-9a-z]+)(?<req_uri>/.*)?$`.
   - Chybějící lomítko (`/web1`) přesměruje 301 na `/web1/`.
   - Předává nezměněnou URL cestu na kontejner `http://${site}-wordpress:80`.
   - Předává hlavičky `Host`, `X-Forwarded-Host`, `X-Forwarded-Proto`, `X-Forwarded-Prefix`.

2. **WordPress Symlink v kontejneru:**
   - V rootu kontejneru `/var/www/html/` existuje symlink `web1 -> .`.
   - Když Apache obdrží požadavek `/web1/index.php` nebo `/web1/wp-admin/`, obslouží jej přímo z kořenového adresáře.

3. **Dynamický `wp-config.php`:**
   - Čte `HTTP_HOST` a nastavuje:
     ```php
     define('WP_HOME',    $proto . '://' . $http_host . '/' . $site_name);
     define('WP_SITEURL', $proto . '://' . $http_host . '/' . $site_name);
     ```
   - Díky tomu všechny interní odkazy, CSS styly, JavaScripty a admin ajax směrují správně na `/web1/...` bez nutnosti manuálního přepisování.

