<?php
// ==============================================================================
// Webhosting Manager - Database & App Configuration
// ==============================================================================

// Načtení .env souboru, pokud existuje v kořeni projektu nebo v kontejneru
function load_env_file() {
    $paths = ['/workspace/.env', '/.env', dirname(__DIR__) . '/.env', __DIR__ . '/../.env'];
    foreach ($paths as $path) {
        if (is_file($path) && is_readable($path)) {
            $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            if ($lines === false) continue;
            foreach ($lines as $line) {
                if (strpos(trim($line), '#') === 0) continue;
                if (strpos($line, '=') === false) continue;
                list($key, $val) = explode('=', $line, 2);
                $key = trim($key);
                $val = trim($val, " \t\n\r\0\x0B\"'");
                if (!isset($_ENV[$key])) {
                    $_ENV[$key] = $val;
                    putenv("$key=$val");
                }
            }
            break;
        }
    }
}
load_env_file();

define('DB_HOST', getenv('MYSQL_HOST') ?: '127.0.0.1');
define('DB_PORT', getenv('MYSQL_PORT') ?: '3306');
define('DB_NAME', getenv('ADMIN_DB_NAME') ?: 'webhosting_admin_db');
define('DB_USER', getenv('ADMIN_DB_USER') ?: 'admin_user');
define('DB_PASS', getenv('ADMIN_DB_PASSWORD') ?: 'AdmUsr_6421#mRjP!5yC');

define('SERVER_IP', getenv('SERVER_IP') ?: '192.168.1.100');
define('ADMIN_PORT', getenv('ADMIN_PORT') ?: '8080');

// Získání PDO připojení k databázi administrace
function get_db() {
    static $pdo = null;
    if ($pdo === null) {
        $dsn = "mysql:host=" . DB_HOST . ";port=" . DB_PORT . ";dbname=" . DB_NAME . ";charset=utf8mb4";
        $options = [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_TIMEOUT => 5
        ];
        if (defined('PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT')) {
            $options[PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT] = false;
        }
        try {
            $pdo = new PDO($dsn, DB_USER, DB_PASS, $options);
        } catch (PDOException $e) {
            // Zaznamenání chyby
            error_log("Database connection failed: " . $e->getMessage());
            return null;
        }
    }
    return $pdo;
}

