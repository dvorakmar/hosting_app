<?php
// ==============================================================================
// Webhosting Manager - Hlavní Zákaznický Portál
// ==============================================================================

require_once __DIR__ . '/config.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/functions.php';

$flash_message = null;
$flash_type = 'info';
$last_output = null;

// --- Zpracování akcí (POST požadavky) ---
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    // 1. Přihlášení
    if ($action === 'login') {
        $username = trim($_POST['username'] ?? '');
        $password = $_POST['password'] ?? '';

        if (login($username, $password)) {
            header('Location: index.php');
            exit;
        } else {
            $flash_message = 'Neplatné uživatelské jméno nebo heslo.';
            $flash_type = 'error';
        }
    }

    // 2. Odhlášení
    if ($action === 'logout') {
        logout();
        header('Location: index.php');
        exit;
    }

    // 3. Vytvoření nového WordPress webhostingu
    if ($action === 'create_site' && is_logged_in()) {
        $site_name = strtolower(trim($_POST['site_name'] ?? ''));

        // Validace názvu
        if (!preg_match('/^web[0-9a-z]{1,24}$/', $site_name)) {
            $flash_message = "Neplatný název webu. Název musí začínat předponou 'web' a obsahovat pouze malá písmena a číslice (např. web1, web2, webblog).";
            $flash_type = 'error';
        } else {
            $result = run_script_command('provision.sh', $site_name);
            $last_output = $result['output'];

            if ($result['success']) {
                $flash_message = "Webhosting '{$site_name}' byl úspěšně vytvořen a kontejner spuštěn!";
                $flash_type = 'success';

                // Načtení DB údajů ze souboru db.env
                $sites_dir = dirname(__DIR__) . '/data/sites';
                if (!is_dir($sites_dir)) $sites_dir = '/data/sites';
                $db_env = "{$sites_dir}/{$site_name}/db.env";
                $db_name = "wp_{$site_name}";
                $db_user = $site_name;
                if (file_exists($db_env)) {
                    $creds = parse_ini_file($db_env);
                    $db_name = $creds['DB_NAME'] ?? $db_name;
                    $db_user = $creds['DB_USER'] ?? $db_user;
                }
                save_site_record(get_current_user_id(), $site_name, $db_name, $db_user);
            } else {
                $flash_message = "Chyba při vytváření webhostingu '{$site_name}'. Zkontrolujte log.";
                $flash_type = 'error';
            }
        }
    }

    // 4. Smazání existujícího webhostingu
    if ($action === 'delete_site' && is_logged_in()) {
        $site_name = strtolower(trim($_POST['site_name'] ?? ''));

        if (!preg_match('/^web[0-9a-z]{1,24}$/', $site_name)) {
            $flash_message = "Neplatný název webu ke smazání.";
            $flash_type = 'error';
        } else {
            $result = run_script_command('deprovision.sh', $site_name);
            $last_output = $result['output'];

            if ($result['success']) {
                $flash_message = "Webhosting '{$site_name}' byl úspěšně a bezpečně odstraněn.";
                $flash_type = 'success';
                delete_site_record(get_current_user_id(), $site_name);
            } else {
                $flash_message = "Chyba při mazání webhostingu '{$site_name}'. Zkontrolujte log.";
                $flash_type = 'error';
            }
        }
    }
}

// Data pro přihlášeného zákazníka
$user_sites = is_logged_in() ? get_customer_sites(get_current_user_id()) : [];
$server_ip = SERVER_IP;
$admin_port = ADMIN_PORT;
$base_url = "http://{$server_ip}:{$admin_port}";
?>
<!DOCTYPE html>
<html lang="cs" class="h-full bg-slate-900 text-slate-100">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Webhosting Manager | Home-Lab</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {
            theme: {
                extend: {
                    colors: {
                        brand: {
                            50: '#f0f9ff',
                            500: '#0284c7',
                            600: '#0369a1',
                            700: '#075985'
                        }
                    }
                }
            }
        }
    </script>
</head>
<body class="h-full flex flex-col font-sans">

<?php if (!is_logged_in()): ?>
    <!-- ================================================================= -->
    <!-- 1. PŘIHLAŠOVACÍ OBRAZOVKA                                         -->
    <!-- ================================================================= -->
    <div class="flex-1 flex items-center justify-center p-4">
        <div class="w-full max-w-md bg-slate-800/80 backdrop-blur border border-slate-700/60 rounded-2xl p-8 shadow-2xl">
            <div class="text-center mb-8">
                <div class="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-sky-500/10 border border-sky-500/20 text-sky-400 mb-4">
                    <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
                    </svg>
                </div>
                <h1 class="text-2xl font-bold text-white tracking-tight">Webhosting Manager</h1>
                <p class="text-sm text-slate-400 mt-1">Home-Lab automatizovaný WordPress hosting</p>
            </div>

            <?php if ($flash_message): ?>
                <div class="mb-6 p-4 rounded-xl text-sm bg-rose-500/10 border border-rose-500/30 text-rose-400">
                    <?= htmlspecialchars($flash_message) ?>
                </div>
            <?php endif; ?>

            <form method="POST" action="index.php" class="space-y-5">
                <input type="hidden" name="action" value="login">
                <div>
                    <label class="block text-xs font-semibold uppercase tracking-wider text-slate-400 mb-2">Uživatelské jméno</label>
                    <input type="text" name="username" required value="demo" 
                           class="w-full px-4 py-3 bg-slate-900 border border-slate-700 rounded-xl text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-sky-500 focus:border-transparent transition">
                </div>
                <div>
                    <label class="block text-xs font-semibold uppercase tracking-wider text-slate-400 mb-2">Heslo</label>
                    <input type="password" name="password" required value="demo123" 
                           class="w-full px-4 py-3 bg-slate-900 border border-slate-700 rounded-xl text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-sky-500 focus:border-transparent transition">
                </div>
                <button type="submit" 
                        class="w-full py-3.5 px-4 bg-sky-600 hover:bg-sky-500 text-white font-medium rounded-xl shadow-lg shadow-sky-600/30 transition duration-150 transform active:scale-98">
                    Přihlásit se do klientského panelu
                </button>
            </form>

            <div class="mt-8 pt-6 border-t border-slate-700/60 text-center text-xs text-slate-500">
                <p>Výchozí demo účet: <code class="text-sky-400 bg-slate-900 px-2 py-0.5 rounded">demo</code> / <code class="text-sky-400 bg-slate-900 px-2 py-0.5 rounded">demo123</code></p>
            </div>
        </div>
    </div>

<?php else: ?>
    <!-- ================================================================= -->
    <!-- 2. KLIENTSKÝ DASHBOARD                                            -->
    <!-- ================================================================= -->

    <!-- Horní navigační lišta -->
    <header class="bg-slate-800/90 border-b border-slate-700/80 sticky top-0 z-30 backdrop-blur">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
            <div class="flex items-center space-x-3">
                <div class="w-10 h-10 rounded-xl bg-sky-500/10 border border-sky-500/20 text-sky-400 flex items-center justify-center">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
                    </svg>
                </div>
                <div>
                    <span class="font-bold text-white text-lg tracking-tight">Webhosting Manager</span>
                    <span class="ml-2 text-xs text-sky-400 bg-sky-500/10 px-2 py-0.5 rounded-full border border-sky-500/20">Home-Lab</span>
                </div>
            </div>

            <div class="flex items-center space-x-4">
                <div class="text-right hidden sm:block">
                    <div class="text-sm font-medium text-white"><?= htmlspecialchars(get_current_username()) ?></div>
                    <div class="text-xs text-slate-400">Zákaznický účet</div>
                </div>
                <form method="POST" action="index.php">
                    <input type="hidden" name="action" value="logout">
                    <button type="submit" 
                            class="px-3.5 py-1.5 bg-slate-700 hover:bg-slate-600 text-slate-200 text-sm font-medium rounded-lg transition">
                        Odhlásit
                    </button>
                </form>
            </div>
        </div>
    </header>

    <!-- Hlavní obsah -->
    <main class="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8 space-y-8">

        <!-- Notifikace -->
        <?php if ($flash_message): ?>
            <div class="p-4 rounded-xl text-sm flex items-start space-x-3 <?= $flash_type === 'success' ? 'bg-emerald-500/10 border border-emerald-500/30 text-emerald-300' : 'bg-rose-500/10 border border-rose-500/30 text-rose-300' ?>">
                <div class="flex-1"><?= htmlspecialchars($flash_message) ?></div>
            </div>
        <?php endif; ?>

        <!-- Výpis výstupu skriptu (pokud existuje) -->
        <?php if ($last_output): ?>
            <div class="bg-slate-950 border border-slate-800 rounded-xl p-4">
                <div class="flex items-center justify-between mb-2">
                    <span class="text-xs font-semibold uppercase tracking-wider text-slate-400">Protokol z operace (CLI výstup)</span>
                    <span class="text-xs text-slate-500">provision.sh / deprovision.sh</span>
                </div>
                <pre class="text-xs font-mono text-slate-300 bg-slate-900 p-3 rounded-lg overflow-x-auto max-h-48 whitespace-pre-wrap"><?= htmlspecialchars($last_output) ?></pre>
            </div>
        <?php endif; ?>

        <!-- Informační přehled a konfigurace -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-5">
            <div class="bg-slate-800 border border-slate-700/80 rounded-2xl p-5">
                <div class="text-xs font-semibold uppercase tracking-wider text-slate-400">Serverová adresa</div>
                <div class="mt-2 text-xl font-bold text-white font-mono"><?= htmlspecialchars($server_ip) ?>:<?= htmlspecialchars($admin_port) ?></div>
                <div class="mt-1 text-xs text-slate-400">Přístup přes sdílenou IP adresu a Nginx proxy</div>
            </div>
            <div class="bg-slate-800 border border-slate-700/80 rounded-2xl p-5">
                <div class="text-xs font-semibold uppercase tracking-wider text-slate-400">Aktivní webhostingy</div>
                <div class="mt-2 text-xl font-bold text-sky-400 font-mono"><?= count($user_sites) ?></div>
                <div class="mt-1 text-xs text-slate-400">Izolované WordPress kontejnery</div>
            </div>
            <div class="bg-slate-800 border border-slate-700/80 rounded-2xl p-5">
                <div class="text-xs font-semibold uppercase tracking-wider text-slate-400">Formát adres klientských webů</div>
                <div class="mt-2 text-sm font-semibold text-emerald-400 font-mono">http://IP:PORT/webX/</div>
                <div class="mt-1 text-xs text-slate-400">Sub-path routing s dynamickým wp-config</div>
            </div>
        </div>

        <!-- Sekce: Vytvořit nový webhosting -->
        <div class="bg-slate-800 border border-slate-700/80 rounded-2xl p-6 shadow-xl">
            <h2 class="text-lg font-bold text-white mb-2">Vytvořit nový WordPress webhosting</h2>
            <p class="text-sm text-slate-400 mb-6">
                Systém automaticky vytvoří novou izolovanou MySQL databázi s 6místným náhodným identifikátorem, vygeneruje přístupové údaje do volume a spustí WordPress kontejner.
            </p>

            <form method="POST" action="index.php" class="flex flex-col sm:flex-row items-stretch gap-3 max-w-xl">
                <input type="hidden" name="action" value="create_site">
                <div class="relative flex-1">
                    <span class="absolute inset-y-0 left-0 pl-3 flex items-center text-slate-500 font-mono text-sm">/</span>
                    <input type="text" name="site_name" id="siteNameInput" required placeholder="web1"
                           pattern="^web[0-9a-z]{1,24}$" title="Musí začínat 'web' a obsahovat pouze malá písmena a číslice"
                           class="w-full pl-7 pr-4 py-3 bg-slate-900 border border-slate-700 rounded-xl text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-sky-500 font-mono text-sm transition">
                </div>
                <button type="submit" id="createBtn"
                        class="px-6 py-3 bg-sky-600 hover:bg-sky-500 text-white font-medium rounded-xl shadow-lg shadow-sky-600/30 transition flex items-center justify-center space-x-2">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
                    </svg>
                    <span>Vytvořit web</span>
                </button>
            </form>
            <p class="mt-2 text-xs text-slate-500">Příklad: <code>web1</code>, <code>web2</code>, <code>webblog</code>. Povolený formát: <code>^web[0-9a-z]+$</code>.</p>
        </div>

        <!-- Sekce: Seznam klientských webhostingů -->
        <div class="bg-slate-800 border border-slate-700/80 rounded-2xl overflow-hidden shadow-xl">
            <div class="px-6 py-4 border-b border-slate-700/80 flex items-center justify-between">
                <h2 class="text-lg font-bold text-white">Vaše WordPress instance</h2>
                <span class="text-xs text-slate-400">Celkem: <?= count($user_sites) ?></span>
            </div>

            <?php if (empty($user_sites)): ?>
                <div class="p-12 text-center text-slate-400">
                    <svg class="w-12 h-12 mx-auto text-slate-600 mb-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4" />
                    </svg>
                    <p class="font-medium">Zatím nemáte vytvořen žádný webhosting.</p>
                    <p class="text-xs text-slate-500 mt-1">Zadejte název výše (např. <code>web1</code>) a klikněte na "Vytvořit web".</p>
                </div>
            <?php else: ?>
                <div class="overflow-x-auto">
                    <table class="w-full text-left text-sm">
                        <thead class="bg-slate-900/60 text-xs uppercase tracking-wider text-slate-400 border-b border-slate-700/80">
                            <tr>
                                <th class="px-6 py-3.5">Název webu</th>
                                <th class="px-6 py-3.5">URL adresa (Sub-path)</th>
                                <th class="px-6 py-3.5">MySQL Databáze</th>
                                <th class="px-6 py-3.5">Stav</th>
                                <th class="px-6 py-3.5 text-right">Akce</th>
                            </tr>
                        </thead>
                        <tbody class="divide-y divide-slate-700/60">
                            <?php foreach ($user_sites as $s): ?>
                                <?php 
                                    $site_url = "{$base_url}/{$s['site_name']}/";
                                    $admin_url = "{$base_url}/{$s['site_name']}/wp-admin/";
                                ?>
                                <tr class="hover:bg-slate-750/50 transition">
                                    <td class="px-6 py-4 font-medium text-white font-mono">
                                        <?= htmlspecialchars($s['site_name']) ?>
                                    </td>
                                    <td class="px-6 py-4">
                                        <a href="<?= htmlspecialchars($site_url) ?>" target="_blank" 
                                           class="text-sky-400 hover:text-sky-300 font-mono text-xs inline-flex items-center space-x-1 underline decoration-sky-500/40 underline-offset-2">
                                            <span><?= htmlspecialchars($site_url) ?></span>
                                            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                                            </svg>
                                        </a>
                                    </td>
                                    <td class="px-6 py-4 text-xs font-mono text-slate-300">
                                        <div class="text-slate-200"><?= htmlspecialchars($s['db_name']) ?></div>
                                        <div class="text-slate-500 text-[11px]">User: <?= htmlspecialchars($s['db_user']) ?></div>
                                    </td>
                                    <td class="px-6 py-4">
                                        <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-emerald-500/10 text-emerald-400 border border-emerald-500/20">
                                            Aktivní
                                        </span>
                                    </td>
                                    <td class="px-6 py-4 text-right space-x-2 whitespace-nowrap">
                                        <a href="<?= htmlspecialchars($site_url) ?>" target="_blank"
                                           class="inline-flex items-center px-3 py-1.5 bg-slate-700 hover:bg-slate-600 text-slate-200 text-xs font-medium rounded-lg transition">
                                            Zobrazit
                                        </a>
                                        <a href="<?= htmlspecialchars($admin_url) ?>" target="_blank"
                                           class="inline-flex items-center px-3 py-1.5 bg-sky-700 hover:bg-sky-600 text-white text-xs font-medium rounded-lg transition">
                                            WP Admin
                                        </a>
                                        <form method="POST" action="index.php" class="inline-block" 
                                              onsubmit="return confirm('Opravdu chcete kompletně smazat webhosting \'<?= htmlspecialchars($s['site_name']) ?>\' včetně jeho MySQL databáze a dat kontejneru? Tuto akci nelze vrátit!');">
                                            <input type="hidden" name="action" value="delete_site">
                                            <input type="hidden" name="site_name" value="<?= htmlspecialchars($s['site_name']) ?>">
                                            <button type="submit" 
                                                    class="inline-flex items-center px-3 py-1.5 bg-rose-600/20 hover:bg-rose-600 text-rose-300 hover:text-white border border-rose-500/30 text-xs font-medium rounded-lg transition">
                                                Smazat
                                            </button>
                                        </form>
                                    </td>
                                </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
            <?php endif; ?>
        </div>

    </main>

    <footer class="border-t border-slate-800 py-6 text-center text-xs text-slate-500">
        Webhosting Manager &bull; Home-Lab WordPress Automation &bull; Reverse Proxy + MySQL Cluster Orchestrator
    </footer>

<?php endif; ?>

</body>
</html>

