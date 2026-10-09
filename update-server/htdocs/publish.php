<?php
/**
 * SL 启动器 · 更新服务 —— 一键发版（GitHub → 本站，手动入口）
 *
 * 本地一行命令即可触发（保留此入口作为 Actions 之外的兜底/手动复查）：
 *
 *     curl "https://apple.ct.ws/publish.php?key=<PUBLISH_KEY>"
 *
 * 实际逻辑在 publish_core.php 的 sync_from_github()，与 GitHub Actions
 * 的 sync-server job 共用：
 * 调 GitHub 拉最新 release → 下载 dmg（zip 回退）→ 原子改写 latest.json 等。
 *
 * 鉴权：URL 里的 key 必须与 config.secret.php 的 publish_key_sha256 对应
 * （SHA-256 后 hash_equals 恒定时间比较，防时序侧信道）。
 */

declare(strict_types=1);

define('SL_ENTRY', 1);
$__config    = require __DIR__ . '/config.secret.php';
$KEY_SHA256 = (string) ($__config['publish_key_sha256'] ?? '');

header('Content-Type: text/plain; charset=utf-8');
set_time_limit(300);   // 下载安装包可能耗时，放宽执行上限

/** 输出一行结果并结束。 */
function respond(int $code, string $line): never
{
    http_response_code($code);
    echo $line, "\n";
    exit;
}

// ── 鉴权 ───────────────────────────────────────────────────────────────
$key = (string) ($_GET['key'] ?? $_POST['key'] ?? '');
if ($KEY_SHA256 === '' || !hash_equals($KEY_SHA256, hash('sha256', $key))) {
    respond(403, 'forbidden');
}

// ── 共享发布逻辑（publish_core.php）───────────────────────────────────
require __DIR__ . '/publish_core.php';

$result = sync_from_github(__DIR__);
if (isset($result['error'])) {
    respond(502, $result['error']);
}
respond(200, 'ok ' . $result['ok']);