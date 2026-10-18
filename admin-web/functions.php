<?php
// ==============================================================================
// Webhosting Manager - Core Helper Functions
// ==============================================================================

require_once __DIR__ . '/config.php';

function find_script_path($script_name) {
    $candidates = [
        "/scripts/{$script_name}",
        dirname(__DIR__) . "/scripts/{$script_name}",
        __DIR__ . "/../scripts/{$script_name}"
    ];
    foreach ($candidates as $path) {
        if (file_exists($path)) {
            return $path;
        }
    }
    return false;
}

function run_script_command($script_file, $arg) {
    $script_path = find_script_path($script_file);
    if (!$script_path) {
        return [
            'success' => false,
            'output' => "Skript {$script_file} nebyl nalezen na žádné očekávané cestě.",
            'exit_code' => 127
        ];
    }

    // Bezpečná escapace argumentu
    $safe_arg = escapeshellarg($arg);
    $safe_path = escapeshellcmd($script_path);

    // Pokud existuje lokální uživatel script-deploy a máme sudo práva (na hostiteli)
    $cmd = "bash {$safe_path} {$safe_arg} 2>&1";

    $output = [];
    $exit_code = 0;
    exec($cmd, $output, $exit_code);

    return [
        'success' => ($exit_code === 0),
        'output' => implode("\n", $output),
        'exit_code' => $exit_code
    ];
}

function parse_env_file($path) {
    if (!is_file($path) || !is_readable($path)) {
        return [];
    }
    $data = [];
    $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($lines === false) {
        return [];
    }
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') {
            continue;
        }
        if (strpos($line, '=') !== false) {
            list($key, $value) = explode('=', $line, 2);
            $key = trim($key);
            $value = trim($value, " \t\n\r\0\x0B\"'");
            $data[$key] = $value;
        }
    }
    return $data;
}

function get_customer_sites($customer_id) {
    $db = get_db();
    if ($db) {
        try {
            $stmt = $db->prepare("SELECT * FROM customer_sites WHERE customer_id = :cid ORDER BY created_at DESC");
            $stmt->execute(['cid' => $customer_id]);
            return $stmt->fetchAll();
        } catch (PDOException $e) {
            error_log("Failed to fetch customer sites: " . $e->getMessage());
        }
    }

    // Fallback: Načtení ze souborového systému (data/sites) pro případ výpadku DB
    $sites = [];
    $sites_dir = dirname(__DIR__) . '/data/sites';
    if (!is_dir($sites_dir)) {
        $sites_dir = '/data/sites';
    }
    if (is_dir($sites_dir)) {
        $dirs = scandir($sites_dir);
        foreach ($dirs as $d) {
            if ($d === '.' || $d === '..') continue;
            if (is_dir("{$sites_dir}/{$d}") && preg_match('/^web[0-9a-z]+$/', $d)) {
                $db_env = "{$sites_dir}/{$d}/db.env";
                $db_name = 'Neznámá';
                $db_user = 'Neznámý';
                if (file_exists($db_env)) {
                    $ini = parse_env_file($db_env);
                    $db_name = $ini['DB_NAME'] ?? $db_name;
                    $db_user = $ini['DB_USER'] ?? $db_user;
                }
                $sites[] = [
                    'id' => 0,
                    'customer_id' => $customer_id,
                    'site_name' => $d,
                    'db_name' => $db_name,
                    'db_user' => $db_user,
                    'status' => 'active',
                    'url_path' => "/{$d}/",
                    'created_at' => date('Y-m-d H:i:s', filemtime("{$sites_dir}/{$d}"))
                ];
            }
        }
    }
    return $sites;
}

function save_site_record($customer_id, $site_name, $db_name, $db_user) {
    $db = get_db();
    if (!$db) return false;

    try {
        $stmt = $db->prepare("
            INSERT INTO customer_sites (customer_id, site_name, db_name, db_user, status, url_path)
            VALUES (:cid, :site, :dbname, :dbuser, 'active', :url)
            ON DUPLICATE KEY UPDATE db_name = VALUES(db_name), db_user = VALUES(db_user), status = 'active'
        ");
        return $stmt->execute([
            'cid' => $customer_id,
            'site' => $site_name,
            'dbname' => $db_name,
            'dbuser' => $db_user,
            'url' => "/{$site_name}/"
        ]);
    } catch (PDOException $e) {
        error_log("Failed to save site record: " . $e->getMessage());
        return false;
    }
}

function delete_site_record($customer_id, $site_name) {
    $db = get_db();
    if (!$db) return false;

    try {
        $stmt = $db->prepare("DELETE FROM customer_sites WHERE customer_id = :cid AND site_name = :site");
        return $stmt->execute([
            'cid' => $customer_id,
            'site' => $site_name
        ]);
    } catch (PDOException $e) {
        error_log("Failed to delete site record: " . $e->getMessage());
        return false;
    }
}

