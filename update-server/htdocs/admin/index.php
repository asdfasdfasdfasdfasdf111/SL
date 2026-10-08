<?php
/**
 * SL 启动器 · 更新服务 —— 管理页（发版登记，唯一会写文件的 PHP 页面）。
 *
 * 发版流程（零美元档：没有 SSH / 没有 Git / 没有 cron，只有 FTP + PHP）：
 *   1. CI 打出 qwq-<版本>.zip 后，用 FTP 把它传到 htdocs/updates/ 目录；
 *   2. 打开本页 → 选 zip → 填版本号与更新说明 → 「发布」；
 *   3. 本页原子改写两个 JSON：
 *        api/latest.json    —— App 检查更新读它（GitHub releases/latest 同形）
 *        data/releases.json —— 公开页与历史列表读它
 *   4. 完成。所有已装旧版 App 下次启动即收到更新提示。
 *
 * 鉴权：文件级密码。首次部署后**必须**改掉下方 ADMIN_PASSWORD 里的默认值
 *（改成只有你知道的一长串），否则任何人都能替你发版。会话用 PHP session。
 */

declare(strict_types=1);

// ── 配置（部署后按需修改这两行）───────────────────────────────────────────
const ADMIN_PASSWORD = 'change-me-please';   // ⚠️ 部署后立刻改掉
const RELEASES_KEPT  = 10;                    // releases.json 保留最近多少个版本
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

session_start();

/** 是否已登录。 */
function is_logged_in(): bool
{
    return !empty($_SESSION['sl_admin_authed']);
}

/** 列出 updates/ 里的 zip（文件名排序，新上传的未必名字最新——按 mtime 倒序更直观）。 */
function list_zips(string $dir): array
{
    $out = [];
    foreach (glob($dir . '/*.zip') ?: [] as $path) {
        $out[] = [
            'name' => basename($path),
            'size' => filesize($path) ?: 0,
            'mtime' => filemtime($path) ?: 0,
        ];
    }
    usort($out, fn($a, $b) => $b['mtime'] <=> $a['mtime']);
    return $out;
}

/** 读 releases.json（没有/坏了都返回空数组，管理页永不因数据坏掉而 500）。 */
function load_releases(string $dataDir): array
{
    $path = $dataDir . '/releases.json';
    if (!is_file($path)) {
        return [];
    }
    $decoded = json_decode((string) file_get_contents($path), true);
    return (is_array($decoded) && isset($decoded['releases']) && is_array($decoded['releases']))
        ? $decoded['releases'] : [];
}

/** 原子写文件：先写临时文件再 rename（读方永远读到完整 JSON，不会读到半截）。 */
function atomic_write(string $path, string $contents): bool
{
    $tmp = $path . '.tmp.' . getmypid();
    if (file_put_contents($tmp, $contents) === false) {
        return false;
    }
    return rename($tmp, $path);
}

/** 当前站点的绝对 URL 前缀（assets.browser_download_url 要绝对地址）。 */
function site_base(): string
{
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    return $scheme . '://' . ($_SERVER['HTTP_HOST'] ?? 'apple.ct.ws');
}

/** 版本号是否合法：可选 v 前缀 + 至少一段数字（与 App 端逐段数值比较兼容）。 */
function valid_tag(string $tag): bool
{
    return (bool) preg_match('/^v?\d+(\.\d+)*$/', $tag);
}

/** 单个 release 记录（GitHub releases/latest 同形，App 解析端零改动兼容）。 */
function build_release(string $tag, string $body, string $zipName, int $zipSize, string $base): array
{
    return [
        'tag_name'       => $tag,
        'name'           => 'SL 启动器 ' . $tag,
        'body'           => $body,
        'published_at'   => gmdate('Y-m-d\TH:i:s\Z'),
        'assets'         => [[
            'name'               => $zipName,
            'browser_download_url' => $base . '/updates/' . rawurlencode($zipName),
            'size'               => $zipSize,
        ]],
    ];
}

/** 把 releases 数组写成 latest.json + releases.json。 */
function publish(array $releases, string $apiDir, string $dataDir): bool
{
    $flags = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT;
    if (!atomic_write($apiDir . '/latest.json', json_encode($releases[0], $flags) ?: '')) {
        return false;
    }
    return atomic_write($dataDir . '/releases.json',
        json_encode(['releases' => array_values($releases)], $flags) ?: '');
}

$message = '';   // 结果提示（发布/删除/登录失败）
$error   = '';

// ── 登录 / 登出 ───────────────────────────────────────────────────────────
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'login') {
        if (hash_equals(ADMIN_PASSWORD, (string) ($_POST['password'] ?? ''))) {
            session_regenerate_id(true);   // 登录成功换会话 ID（防会话固定）
            $_SESSION['sl_admin_authed'] = true;
        } else {
            $error = '密码不对。若你还没改过 ADMIN_PASSWORD，先去 admin/index.php 顶部改掉默认值。';
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

            if (publish($releases, $API_DIR, $DATA_DIR)) {
                $message = "已发布 {$tag}（{$zip}）。旧版 App 下次启动即会收到更新提示。";
            } else {
                $error = '写入失败：检查 api/ 与 data/ 目录权限（FTP 客户端里改为 755 或 775）。';
            }
        }
    } elseif ($action === 'delete' && is_logged_in()) {
        $tag = trim((string) ($_POST['tag'] ?? ''));
        $releases = array_values(array_filter(load_releases($DATA_DIR),
            fn($r) => ($r['tag_name'] ?? '') !== $tag));
        if (publish($releases, $API_DIR, $DATA_DIR)) {
            $message = "已从列表移除 {$tag}（zip 文件仍在 updates/，可 FTP 删除）。";
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
                <label>安装包（updates/ 目录里的 zip）</label>
                <?php if ($zips === []): ?>
                    <div class="hint">updates/ 里还没有 zip。先用 FTP 把 CI 打好的 qwq-&lt;版本&gt;.zip 传进去，再刷新本页。</div>
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
