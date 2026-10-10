<?php
/**
 * SL 启动器 · 更新服务 —— 发布核心（共享逻辑）
 *
 * 被两类入口共用：
 *   · publish.php   手动一键发布（curl "…/publish.php?key=…"）
 *   · GitHub Actions 的 sync-server job（发布 Release 时自动同步，发布即生效）
 *     （Actions 的 runner 先解 slowAES 挑战，再带 Cookie 调 publish.php?key=…）
 *
 * 职责：
 *   1. 调 GitHub Releases API 拉最新 release（tag_name / body / 资产）；
 *   2. 把安装包（dmg 优先，zip 回退）下载到 updates/（**同资产 id** 且大小一致才跳过）；
 *   3. 原子改写 api/latest.json + data/releases.json（App 解析端零改动兼容）；
 *   4. 清理旧命名的历史包（见 cleanup_old_packages），避免免费主机配额被逐版吃掉。
 *
 * 无 SSH / cron / 数据库：全靠 HTTP 入口触发，免费档即可运行。
 * 鉴权不在本文件 —— 由各自入口负责（命令行 / Actions 触发时带 PUBLISH_KEY）。
 */

declare(strict_types=1);

// 非入口直访（如直接请求 publish_core.php）一律 404——本文件只是共享函数库，
// 只能被 publish.php / admin/index.php 在定义 SL_ENTRY 后 require。
if (!defined('SL_ENTRY')) {
    http_response_code(404);
    exit;
}

if (!defined('GH_UA'))  define('GH_UA', 'SL-Update-Publisher/1.0'); // GitHub API 强制要求 UA
if (!defined('GH_API_URL')) define('GH_API_URL',
    'https://api.github.com/repos/asdfasdfasdfasdfasdf111/SL/releases/latest');
if (!defined('RELEASES_KEPT')) define('RELEASES_KEPT', 10);

/** GET GitHub API（跟随重定向，带 UA）。失败返回 error 键。 */
function gh_get(string $url): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_CONNECTTIMEOUT => 15,
        CURLOPT_TIMEOUT       => 30,
        CURLOPT_USERAGENT     => GH_UA,
        CURLOPT_HTTPHEADER    => ['Accept: application/vnd.github+json'],
    ]);
    $body = curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $err  = curl_error($ch);
    curl_close($ch);

    if ($body === false || $code >= 400) {
        return ['error' => "GitHub HTTP {$code} " . ($err !== '' ? $err : substr((string) $body, 0, 120))];
    }
    $json = json_decode((string) $body, true);
    return is_array($json) ? $json : ['error' => 'GitHub returned non-JSON'];
}

/** 流式下载安装包到 updates/（不整包进内存，免费档内存小）。 */
function gh_download(string $url, string $dest): array
{
    $fp = fopen($dest, 'wb');
    if ($fp === false) {
        return ['error' => "cannot open {$dest}"];
    }
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_FILE       => $fp,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_CONNECTTIMEOUT => 15,
        CURLOPT_TIMEOUT    => 280,
        CURLOPT_USERAGENT  => GH_UA,
    ]);
    curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $err  = curl_error($ch);
    curl_close($ch);
    fclose($fp);

    if ($code >= 400 || $err !== '' || !is_file($dest) || filesize($dest) === 0) {
        @unlink($dest);
        return ['error' => "download failed HTTP {$code} " . $err];
    }
    return ['ok' => true, 'size' => (int) filesize($dest)];
}

/** 读 releases.json（没有/坏了返回空数组）。 */
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

/** 原子写文件：先写临时文件再 rename。 */
function atomic_write(string $path, string $contents): bool
{
    $tmp = $path . '.tmp.' . getmypid();
    if (file_put_contents($tmp, $contents) === false) {
        return false;
    }
    return rename($tmp, $path);
}

/**
 * 上次发布写入的包标记（GitHub 资产 id / 资产名 / tag）。
 *
 * 为什么要它：包名现在固定为 `qwq.dmg`，只靠「文件存在且大小一致」判断
 * 「这个包已经在服务器上了」是不够的 —— 新旧包大小若碰巧相同（同一个工具链、
 * 同一份依赖，完全可能），服务器就会**留着旧包却对外宣称新版本**，
 * 客户端装完仍报旧版、反复提示更新。资产 id 是 GitHub 分配的唯一值，比对它才可靠。
 */
function load_pkg_marker(string $dataDir): array
{
    $path = $dataDir . '/pkg.json';
    if (!is_file($path)) {
        return [];
    }
    $json = json_decode((string) @file_get_contents($path), true);
    return is_array($json) ? $json : [];
}

function save_pkg_marker(string $dataDir, string $assetId, string $pkgName, string $tag): void
{
    atomic_write($dataDir . '/pkg.json', json_encode([
        'asset_id' => $assetId,
        'name'     => $pkgName,
        'tag'      => $tag,
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) ?: '');
}

/**
 * 删掉 updates/ 里**旧命名**的历史安装包（`qwq-<版本>.dmg` / `.zip`）与失败残留的 `.part`。
 *
 * 包名固定为 `qwq.dmg` 之后，带版本号的那些文件不会再被 latest.json 引用，
 * 留着只会吃免费主机的磁盘配额（实测发三版就堆了 45 MB）。只匹配严格模式，
 * 且显式排除本次发布的包 —— `.htaccess` / `*.json` / 其它任何文件都不碰。
 *
 * @return int 实际删掉的个数
 */
function cleanup_old_packages(string $updDir, string $keepName): int
{
    $removed = 0;
    $candidates = array_merge(
        (array) glob($updDir . '/qwq-*.dmg'),
        (array) glob($updDir . '/qwq-*.zip'),
        (array) glob($updDir . '/qwq*.part')
    );
    foreach ($candidates as $path) {
        $name = basename((string) $path);
        if ($name === $keepName) {
            continue;   // 本次发布正在对外提供的包
        }
        if (!preg_match('/^qwq-[A-Za-z0-9._-]+\.(dmg|zip)$/i', $name)
            && !preg_match('/^qwq\.dmg\.part$/', $name)) {
            continue;   // 严格白名单，拒绝一切意料之外的文件名
        }
        if (is_file($path) && @unlink($path)) {
            $removed++;
        }
    }
    return $removed;
}

/** 单个 release 记录（GitHub releases/latest 同形）。 */
function build_release(string $tag, string $body, string $pkgName, int $pkgSize, string $base): array
{
    return [
        'tag_name'     => $tag,
        'name'         => 'SL 启动器 ' . $tag,
        'body'         => $body,
        'published_at' => gmdate('Y-m-d\TH:i:s\Z'),
        'assets'       => [[
            'name'                 => $pkgName,
            'browser_download_url' => $base . '/updates/' . rawurlencode($pkgName),
            'size'                 => $pkgSize,
        ]],
    ];
}

/** 写成 latest.json + releases.json。 */
function publish_releases(array $releases, string $apiDir, string $dataDir): bool
{
    $flags = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT;
    $latestPath = $apiDir . '/latest.json';

    if ($releases === []) {
        if (is_file($latestPath) && !unlink($latestPath)) {
            return false;
        }
    } elseif (!atomic_write($latestPath, json_encode($releases[0], $flags) ?: '')) {
        return false;
    }
    return atomic_write($dataDir . '/releases.json',
        json_encode(['releases' => array_values($releases)], $flags) ?: '');
}

/**
 * 从 GitHub 拉最新 release 并同步到本站（下载包 + 原子写两个 JSON）。
 * 成功返回 ['ok' => 'v1.6.1 (qwq-v1.6.1.dmg, 17.5 MB)']，失败返回 ['error' => …]。
 */
function sync_from_github(string $root): array
{
    $DATA_DIR = $root . '/data';
    $API_DIR  = $root . '/api';
    $UPD_DIR  = $root . '/updates';
    foreach ([$DATA_DIR, $API_DIR, $UPD_DIR] as $dir) {
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }
    }
    if (!function_exists('curl_init')) {
        return ['error' => 'server has no curl'];
    }

    $rel = gh_get(GH_API_URL);
    if (isset($rel['error'])) {
        return ['error' => 'github: ' . $rel['error']];
    }

    $tag  = trim((string) ($rel['tag_name'] ?? ''));
    $body = trim((string) ($rel['body'] ?? ''));
    if ($tag === '') {
        return ['error' => 'github: release has no tag_name'];
    }

    // 找安装包资产：dmg 优先（.app 分发首选，权限/签名完整保留），zip 回退
    $asset = null;
    foreach (['.dmg', '.zip'] as $ext) {
        foreach (($rel['assets'] ?? []) as $a) {
            if (is_array($a) && strtolower(substr((string) ($a['name'] ?? ''), -4)) === $ext) {
                $asset = $a;
                break 2;
            }
        }
    }
    if ($asset === null) {
        return ['error' => 'github: latest release has no dmg/zip asset'];
    }

    $pkgName = (string) $asset['name'];
    $pkgUrl  = (string) ($asset['browser_download_url'] ?? '');
    $pkgPath = $UPD_DIR . '/' . $pkgName;

    // 已存在、大小一致**且资产 id 与上次发布的一致** → 跳过下载。
    // 只比大小不够：包名固定为 qwq.dmg 时，新旧包大小相同会留着旧包当好包（见 load_pkg_marker 说明）。
    $expect    = (int) ($asset['size'] ?? 0);
    $assetId   = (string) ($asset['id'] ?? '');
    $marker    = load_pkg_marker($DATA_DIR);
    $sameAsset = $assetId !== ''
        && ($marker['asset_id'] ?? '') === $assetId
        && ($marker['name'] ?? '') === $pkgName;
    if (is_file($pkgPath) && $expect > 0 && filesize($pkgPath) === $expect && $sameAsset) {
        $size = $expect;
    } else {
        $dl = gh_download($pkgUrl, $pkgPath . '.part');
        if (isset($dl['error'])) {
            return ['error' => 'download: ' . $dl['error']];
        }
        if (!rename($pkgPath . '.part', $pkgPath)) {
            return ['error' => 'cannot move package into updates/'];
        }
        $size = (int) $dl['size'];
        save_pkg_marker($DATA_DIR, $assetId, $pkgName, $tag);
    }

    // 写两个 JSON（同 tag 覆盖，否则插到最前，保留最近 RELEASES_KEPT 条）
    $releases = array_values(array_filter(load_releases($DATA_DIR),
        fn($r) => ($r['tag_name'] ?? '') !== $tag));
    $base = 'https://' . ($_SERVER['HTTP_HOST'] ?? 'apple.ct.ws');
    array_unshift($releases, build_release($tag, $body, $pkgName, $size, $base));
    $releases = array_slice($releases, 0, RELEASES_KEPT);

    if (!publish_releases($releases, $API_DIR, $DATA_DIR)) {
        return ['error' => 'write failed: check api/ and data/ permissions'];
    }

    // 清理旧命名（qwq-<版本>.dmg/zip）的历史包：固定名生效后它们不再被 latest.json 引用。
    // 放在发布成功之后——写 JSON 失败时一个字节都不删。
    $removed = cleanup_old_packages($UPD_DIR, $pkgName);

    return ['ok' => "{$tag} ({$pkgName}, " . number_format(round($size / 1048576, 1), 1) . ' MB)'
        . ($removed > 0 ? "，清理旧包 {$removed} 个" : '')];
}