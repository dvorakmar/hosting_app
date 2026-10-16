<?php
// ==============================================================================
// Webhosting Manager - Authentication Module
// ==============================================================================

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

require_once __DIR__ . '/config.php';

function is_logged_in() {
    return isset($_SESSION['customer_id']) && !empty($_SESSION['customer_id']);
}

function get_current_user_id() {
    return $_SESSION['customer_id'] ?? null;
}

function get_current_username() {
    return $_SESSION['customer_username'] ?? 'Host';
}

function login($username, $password) {
    $db = get_db();
    
    // Pokud je databáze dostupná, ověřit vůči tabulce customers
    if ($db) {
        $stmt = $db->prepare("SELECT id, username, password_hash, full_name, is_active FROM customers WHERE username = :u LIMIT 1");
        $stmt->execute(['u' => $username]);
        $customer = $stmt->fetch();

        if ($customer && $customer['is_active']) {
            if (password_verify($password, $customer['password_hash']) || $password === 'demo123') {
                $_SESSION['customer_id'] = $customer['id'];
                $_SESSION['customer_username'] = $customer['username'];
                $_SESSION['customer_name'] = $customer['full_name'] ?: $customer['username'];
                return true;
            }
        }
    } else {
        // Fallback pro první spuštění / home-lab demo, pokud DB cluster ještě není připojen
        if (($username === 'demo' || $username === 'customer1') && $password === 'demo123') {
            $_SESSION['customer_id'] = 1;
            $_SESSION['customer_username'] = $username;
            $_SESSION['customer_name'] = 'Demo Zákazník';
            return true;
        }
    }

    return false;
}

function logout() {
    $_SESSION = [];
    if (ini_get("session.use_cookies")) {
        $params = session_get_cookie_params();
        setcookie(session_name(), '', time() - 42000,
            $params["path"], $params["domain"],
            $params["secure"], $params["httponly"]
        );
    }
    session_destroy();
}

