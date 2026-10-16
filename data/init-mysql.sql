-- ==============================================================================
-- MySQL Cluster Initialization Script - Webhosting Manager
-- ==============================================================================
-- Tento skript inicializuje provozní uživatele v MySQL Master uzlu
-- a připraví databázi pro zákaznický administrační panel.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Provozní uživatel pro PROVISIONING (webhosting_admin)
-- ------------------------------------------------------------------------------
-- Bezpečnostní zásada: Tento účet MÁ práva vytvářet databáze a uživatele pro
-- nové klientské weby, ale NEMÁ globální právo DROP DATABASE. Nemůže tedy
-- omylem ani útokem smazat systémové databáze (mysql, sys, webhosting_admin_db).
-- ------------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'webhosting_admin'@'%' IDENTIFIED BY 'WhAdm_9842#kTxL!7qZ';
ALTER USER 'webhosting_admin'@'%' IDENTIFIED BY 'WhAdm_9842#kTxL!7qZ';

-- Právo zakládat nové databáze na serveru
GRANT CREATE ON *.* TO 'webhosting_admin'@'%';

-- Právo vytvářet uživatelské účty pro klienty
GRANT CREATE USER ON *.* TO 'webhosting_admin'@'%';

-- Právo číst informace o schématech
GRANT SELECT ON *.* TO 'webhosting_admin'@'%';

-- Plná práva k přidělování na zákaznické databáze s prefixem wp_%
-- Včetně WITH GRANT OPTION, aby mohl nově vytvořenému uživateli přidělit práva k jeho DB
GRANT ALL PRIVILEGES ON `wp_%`.* TO 'webhosting_admin'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;

-- ------------------------------------------------------------------------------
-- 2. Vyhrazený uživatel pro DEPROVISIONING (deprovision_admin)
-- ------------------------------------------------------------------------------
-- Bezpečnostní zásada: Tento účet se používá výhradně v přísně izolovaném skriptu
-- deprovision.sh. Má oprávnění DROP POUZE nad databázemi s prefixem wp_%,
-- nikdy ne nad celým serverem (*.*)!
-- ------------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'deprovision_admin'@'%' IDENTIFIED BY 'DeprAdm_3719#vBnK!8wX';
ALTER USER 'deprovision_admin'@'%' IDENTIFIED BY 'DeprAdm_3719#vBnK!8wX';

-- Oprávnění smazat POUZE klientské WordPress databáze
GRANT DROP ON `wp_%`.* TO 'deprovision_admin'@'%';

-- Oprávnění smazat klientského MySQL uživatele
GRANT CREATE USER ON *.* TO 'deprovision_admin'@'%';

-- Oprávnění ověřit existenci databáze
GRANT SELECT ON `wp_%`.* TO 'deprovision_admin'@'%';

FLUSH PRIVILEGES;

-- ------------------------------------------------------------------------------
-- 3. Databáze a uživatel pro Admin Panel (webhosting_admin_db)
-- ------------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS `webhosting_admin_db` 
    CHARACTER SET utf8mb4 
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'admin_user'@'%' IDENTIFIED BY 'AdmUsr_6421#mRjP!5yC';
ALTER USER 'admin_user'@'%' IDENTIFIED BY 'AdmUsr_6421#mRjP!5yC';
GRANT ALL PRIVILEGES ON `webhosting_admin_db`.* TO 'admin_user'@'%';
FLUSH PRIVILEGES;

USE `webhosting_admin_db`;

-- Tabulka administrátorů / interních uživatelů
CREATE TABLE IF NOT EXISTS `admin_users` (
    `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `username` VARCHAR(100) NOT NULL UNIQUE,
    `password_hash` VARCHAR(255) NOT NULL,
    `email` VARCHAR(255),
    `created_at` DATETIME DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_username (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Tabulka zákazníků (Home-lab zákaznické účty pro login do webu)
CREATE TABLE IF NOT EXISTS `customers` (
    `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `username` VARCHAR(100) NOT NULL UNIQUE,
    `email` VARCHAR(255),
    `password_hash` VARCHAR(255) NOT NULL,
    `full_name` VARCHAR(150),
    `is_active` TINYINT(1) DEFAULT 1,
    `created_at` DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_username (`username`),
    INDEX idx_email (`email`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Tabulka klientských WordPress webhostingů
CREATE TABLE IF NOT EXISTS `customer_sites` (
    `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `customer_id` INT UNSIGNED NOT NULL,
    `site_name` VARCHAR(100) NOT NULL UNIQUE,
    `db_name` VARCHAR(100) NOT NULL,
    `db_user` VARCHAR(100) NOT NULL,
    `status` ENUM('provisioning', 'active', 'error', 'deprovisioning') DEFAULT 'active',
    `wp_version` VARCHAR(50) DEFAULT '6.7',
    `url_path` VARCHAR(255) NOT NULL,
    `created_at` DATETIME DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (`customer_id`) REFERENCES `customers`(`id`) ON DELETE CASCADE,
    INDEX idx_site_name (`site_name`),
    INDEX idx_customer_id (`customer_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ------------------------------------------------------------------------------
-- 4. Výchozí demo zákazníci
-- ------------------------------------------------------------------------------
-- Heslo: demo123 (hash vygenerován standardním PHP password_hash)
INSERT INTO `webhosting_admin_db`.`customers` (`username`, `email`, `password_hash`, `full_name`) VALUES
('customer1', 'customer1@homelab.local', '$2y$10$eA0q48lVw8R5aB9T5p60EuQeXmZqD6Pvyg6N3hC1UqmN2M7hT.3yG', 'Zákazník 1'),
('demo',      'demo@homelab.local',      '$2y$10$eA0q48lVw8R5aB9T5p60EuQeXmZqD6Pvyg6N3hC1UqmN2M7hT.3yG', 'Demo Uživatel')
ON DUPLICATE KEY UPDATE `username` = VALUES(`username`);
