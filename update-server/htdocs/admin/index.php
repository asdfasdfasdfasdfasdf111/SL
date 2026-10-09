<?php
/**
 * SL 启动器 · 更新服务 —— 管理页（手动发版兜底）
 *
 * 主发版路径：GitHub Actions 发布 Release 时自动调 publish.php 同步（零手工）；
 * 本页是网页兜底：把 updates/ 里已有的安装包登记成新版本（登录 → 选包 → 发布），
 * 与 publish.php 共用 publish_core.php 的读写逻辑，无重复实现。
 *
 * 鉴权：文件级密码（哈希存于 htdocs/config.secret.php，不提交 git）。
 */

declare(strict_types=1);

// ── 配置（部署后按需修改）─────────────────────────────────────────────
// 管理密码与一键发布 key 都不写在源码里：在 htdocs/config.secret.php 里
// 各存一份哈希，本文件运行时加载。直接访问 config.secret.php 会 404。
define('SL_ENTRY', 1);
$__config = require dirname(__DIR__) . '/config.secret.php';
define('ADMIN_SALT',  (string) ($__config['admin_salt'] ?? ''));
define('ADMIN_PASSWORD_HASH', (string) ($__config['admin_password_hash'] ?? ''));
// ──────────────────────────────────────────────────────────────────────────

$ROOT     = dirname(__DIR__);          // htdocs/
$DATA_DIR = $ROOT . '/data';
$API_DIR  = $ROOT . '/api';
$UPD_DIR  = $ROOT . '/updates';

foreach ([$DATA_DIR, $API_DIR, $UPD_DIR] as $dir) {
    if (!is_dir($dir)) {
        mkdir($dir, 0755, true);
    }
}

ini_set('session.use_strict_mode', '1');   // 未登记的会话 ID 一律重新生成（配合登录时的 regenerate 防会话固定）
session_set_cookie_params([
    'httponly' => true,
    'samesite' => 'Lax',                   // 跨站 POST 不带 cookie：写操作有 CSRF 令牌，浏览器这层再兜一道
    'secure'   => (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off'),
]);
session_start();

/** 是否已登录。 */
function is_logged_in(): bool
{
    return !empty($_SESSION['sl_admin_authed']);
}

// ── 共享发布读写逻辑（load_releases / atomic_write / build_release /
//    publish_releases / RELEASES_KEPT）统一来自 publish_core.php，避免双份实现 ──
require __DIR__ . '/../publish_core.php';

/** 列出 updates/ 里的安装包（dmg 与 zip；按 mtime 倒序更直观）。 */
function list_zips(string $dir): array
{
    $out = [];
    foreach (glob($dir . '/*.{dmg,zip}', GLOB_BRACE) ?: [] as $path) {
        $out[] = [
            'name' => basename($path),
            'size' => filesize($path) ?: 0,
            'mtime' => filemtime($path) ?: 0,
        ];
    }
    usort($out, fn($a, $b) => $b['mtime'] <=> $a['mtime']);
    return $out;
}

/**
 * 当前站点的绝对 URL 前缀（assets.browser_download_url 要绝对地址）。
 *
 * 线上**一律写 https**：App 的 ATS 默认拒绝明文下载，若管理页是经 http 打开的，
 * 把请求里的 scheme 原样烧进 JSON 会让客户端「立即更新」在下载一步直接失败。
 * 本地调试（php -S 跑 127.0.0.1/localhost）保留实际 scheme，否则本机没法下载验证。
 */
function site_base(): string
{
    $host = $_SERVER['HTTP_HOST'] ?? 'apple.ct.ws';
    if (preg_match('/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/', $host)) {
        $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
        return $scheme . '://' . $host;
    }
    return 'https://' . $host;
}

/** 版本号是否合法：可选 v 前缀 + 至少一段数字（与 App 端逐段数值比较兼容）。 */
function valid_tag(string $tag): bool
{
    return (bool) preg_match('/^v?\d+(\.\d+)*$/', $tag);
}

$message = '';   // 结果提示（发布/删除/登录失败）
$error   = '';

// ── 登录 / 登出 ───────────────────────────────────────────────────────────
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        // SHA-256(salt + 密码)：恒定时间比较，config 里只有哈希与盐
        $given = hash('sha256', ADMIN_SALT . (string) ($_POST['password'] ?? ''));
        if (ADMIN_PASSWORD_HASH !== '' && hash_equals(ADMIN_PASSWORD_HASH, $given)) {
            session_regenerate_id(true);   // 登录成功换会话 ID（防会话固定）
            $_SESSION['sl_admin_authed'] = true;
        } else {
            $error = '密码不对。管理密码在 htdocs/config.secret.php 里（哈希），改那里即可。';
        }
    } elseif ($action === 'logout') {
        $_SESSION = [];
        session_destroy();
    } elseif ($action === 'publish' && is_logged_in()) {
        $tag    = trim((string) ($_POST['tag'] ?? ''));
        $body   = trim((string) ($_POST['body'] ?? ''));
        $zip    = basename((string) ($_POST['zip'] ?? ''));
        $zipPath = $UPD_DIR . '/' . $zip;

        if ($tag === '' || !valid_tag($tag)) {
            $error = '版本号不合法：应为 v1.7.0 或 1.7.0 这种形式（数字逐段以点分隔）。';
        } elseif ($zip === '' || !is_file($zipPath)) {
            $error = '请选择一个 updates/ 里确实存在的 zip。';
        } else {
            // 同 tag 重发 = 覆盖该条；否则插到最前。保留最近 RELEASES_KEPT 条。
            $releases = load_releases($DATA_DIR);
            $releases = array_values(array_filter($releases, fn($r) => ($r['tag_name'] ?? '') !== $tag));
            array_unshift($releases, build_release($tag, $body, $zip, (int) filesize($zipPath), site_base()));
            $releases = array_slice($releases, 0, RELEASES_KEPT);

            if (publish_releases($releases, $API_DIR, $DATA_DIR)) {
                $message = "已发布 {$tag}（{$zip}）。旧版 App 下次启动即会收到更新提示。";
            } else {
                $error = '写入失败：检查 api/ 与 data/ 目录权限（改为 755 或 775）。';
            }
        }
    } elseif ($action === 'delete' && is_logged_in()) {
        $tag = trim((string) ($_POST['tag'] ?? ''));
        $releases = array_values(array_filter(load_releases($DATA_DIR),
            fn($r) => ($r['tag_name'] ?? '') !== $tag));
        if (publish_releases($releases, $API_DIR, $DATA_DIR)) {
            $message = "已从列表移除 {$tag}（安装包文件仍在 updates/）。";
        } else {
            $error = '写入失败（见上）。';
        }
    }
}

$zips      = list_zips($UPD_DIR);
$releases  = load_releases($DATA_DIR);
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SL 更新服务 · 管理</title>
<style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        min-height: 100vh; padding: 36px 16px;
        font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
        background: linear-gradient(135deg, #e8853a, #d4547a, #7b4fb8, #e8853a);
        background-size: 300% 300%; animation: drift 18s ease-in-out infinite;
        color: #2b2016;
    }
    @keyframes drift { 0%,100%{background-position:0% 20%;} 50%{background-position:100% 80%;} }
    .wrap { max-width: 640px; margin: 0 auto; }
    h1 { color:#fff; font-size:26px; margin-bottom:22px; text-shadow:0 1px 8px rgba(0,0,0,.18); }
    .card {
        background: rgba(255,255,255,.88); border:1px solid rgba(255,255,255,.5);
        border-radius:16px; padding:22px 24px; margin-bottom:18px;
        box-shadow: 0 12px 30px rgba(60,20,10,.22);
    }
    label { display:block; font-size:13px; font-weight:600; color:#7a5b45; margin:14px 0 6px; }
    input[type=text], input[type=password], select, textarea {
        width:100%; font-size:15px; padding:10px 12px;
        border:1px solid rgba(0,0,0,.18); border-radius:10px; background:#fff;
        font-family: inherit;
    }
    textarea { min-height:90px; resize:vertical; }
    .btn {
        display:inline-block; margin-top:18px; cursor:pointer; border:none;
        background:#d4547a; color:#fff; font-weight:600; font-size:15px;
        padding:11px 26px; border-radius:12px; box-shadow:0 6px 16px rgba(212,84,122,.4);
    }
    .btn.ghost { background:rgba(0,0,0,.06); color:#7a5b45; box-shadow:none; }
    .btn:active { transform: translateY(1px); }
    .msg { padding:12px 14px; border-radius:10px; font-size:14px; margin-bottom:16px; }
    .ok  { background:rgba(46,140,80,.14); color:#20603a; }
    .err { background:rgba(200,50,50,.12); color:#8c2424; }
    table { width:100%; border-collapse:collapse; font-size:14px; }
    th,td { text-align:left; padding:8px 6px; border-bottom:1px solid rgba(0,0,0,.08); }
    th { color:#8a7566; font-size:12px; }
    .del { color:#b03a5b; cursor:pointer; border:none; background:none; font-size:13px; text-decoration:underline; padding:0; font-family:inherit; }
    code { background:rgba(0,0,0,.06); border-radius:6px; padding:2px 7px; font-size:12.5px; word-break:break-all; }
    .hint { font-size:12.5px; color:#9a8470; margin-top:6px; line-height:1.7; }
</style>
</head>
<body>
<div class="wrap">
    <h1>SL 更新服务 · 管理页</h1>

    <?php if ($message): ?><div class="msg ok"><?= htmlspecialchars($message, ENT_QUOTES) ?></div><?php endif; ?>
    <?php if ($error):   ?><div class="msg err"><?= htmlspecialchars($error, ENT_QUOTES) ?></div><?php endif; ?>

    <?php if (!is_logged_in()): ?>
        <div class="card">
            <form method="post">
                <input type="hidden" name="action" value="login">
                <label>管理密码</label>
                <input type="password" name="password" autofocus placeholder="ADMIN_PASSWORD（在 admin/index.php 顶部配置）">
                <button class="btn" type="submit">登录</button>
            </form>
        </div>
    <?php else: ?>
        <div class="card">
            <form method="post">
                <input type="hidden" name="action" value="publish">
                <label>安装包（updates/ 目录里的 dmg / zip）</label>
                <?php if ($zips === []): ?>
                    <div class="hint">updates/ 里还没有安装包。GitHub Actions 发版后会自动同步过来，或手动上传一个 dmg/zip 再刷新本页。</div>
                <?php else: ?>
                    <select name="zip" required>
                        <?php foreach ($zips as $z): ?>
                            <option value="<?= htmlspecialchars($z['name'], ENT_QUOTES) ?>">
                                <?= htmlspecialchars($z['name'], ENT_QUOTES) ?>
                                （<?= number_format(round($z['size'] / 1048576, 1), 1) ?> MB）
                            </option>
                        <?php endforeach; ?>
                    </select>
                <?php endif; ?>

                <label>版本号（tag）</label>
                <input type="text" name="tag" placeholder="v1.7.0" required
                       pattern="v?\d+(\.\d+)*" title="形如 v1.7.0 或 1.7.0">

                <label>更新说明（App 更新提示里展示给用户）</label>
                <textarea name="body" placeholder="例：&#10;· 毛玻璃只保留一层&#10;· 修复 …"></textarea>

                <?php if ($zips !== []): ?><button class="btn" type="submit">发布</button><?php endif; ?>
            </form>
            <div class="hint">
                「发布」会原子改写 <code>api/latest.json</code>（App 检查更新读）与
                <code>data/releases.json</code>（本站页面读）。同版本号重发 = 覆盖那一条。
            </div>
        </div>

        <?php if ($releases !== []): ?>
            <div class="card">
                <table>
                    <tr><th>已发布版本</th><th>zip</th><th></th></tr>
                    <?php foreach ($releases as $r): ?>
                        <tr>
                            <td><strong><?= htmlspecialchars((string) ($r['tag_name'] ?? '?'), ENT_QUOTES) ?></strong></td>
                            <td><?= htmlspecialchars((string) ($r['assets'][0]['name'] ?? ''), ENT_QUOTES) ?></td>
                            <td>
                                <form method="post" onsubmit="return confirm('从更新列表移除 <?= htmlspecialchars((string) ($r['tag_name'] ?? ''), ENT_QUOTES) ?>？')">
                                    <input type="hidden" name="action" value="delete">
                                    <input type="hidden" name="tag" value="<?= htmlspecialchars((string) ($r['tag_name'] ?? ''), ENT_QUOTES) ?>">
                                    <button class="del" type="submit">移除</button>
                                </form>
                            </td>
                        </tr>
                    <?php endforeach; ?>
                </table>
            </div>
        <?php endif; ?>

        <form method="post">
            <input type="hidden" name="action" value="logout">
            <button class="btn ghost" type="submit">退出登录</button>
        </form>
    <?php endif; ?>
</div>
</body>
</html>
