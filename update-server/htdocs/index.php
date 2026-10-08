<?php
/**
 * SL 启动器 · 更新服务 —— 公开页（纯展示，只读 data/releases.json）。
 *
 * 架构约定（零美元档：InfinityFree 免费虚拟主机 = PHP-only / 无数据库 / 无 cron）：
 *   · App 检查更新读的是**静态** /api/latest.json（GitHub releases/latest 同形 JSON，
 *     AppUpdateService.parseLatestRelease 可以零改动解析）——请求路径不跑 PHP；
 *   · App 下载的是**静态** /updates/*.zip —— 同样不跑 PHP；
 *   · PHP 只在 /admin（发版登记页）里执行：把 zip 登记成新版本，原子改写
 *     api/latest.json 与 data/releases.json。流程见 update-server/README.md。
 *
 * 本页面在任何数据都缺失时也要能渲染（刚部署、还没发过版的形态）。
 */

declare(strict_types=1);

$DATA_DIR = __DIR__ . '/data';

$releases = [];
if (is_file($DATA_DIR . '/releases.json')) {
    $decoded = json_decode((string) file_get_contents($DATA_DIR . '/releases.json'), true);
    if (is_array($decoded) && isset($decoded['releases']) && is_array($decoded['releases'])) {
        $releases = $decoded['releases'];
    }
}
$latest = $releases[0] ?? null;

/** 取某条记录的第一个 zip 资产；没有则 null。 */
function first_zip(array $release): ?array
{
    foreach (($release['assets'] ?? []) as $asset) {
        if (is_array($asset) && isset($asset['browser_download_url'])) {
            return $asset;
        }
    }
    return null;
}

/** 字节数 → 人话（用于展示包体大小）。 */
function human_size($bytes): string
{
    if (!is_numeric($bytes) || $bytes <= 0) {
        return '';
    }
    $units = ['B', 'KB', 'MB', 'GB'];
    $value = (float) $bytes;
    foreach ($units as $unit) {
        if ($value < 1024 || $unit === 'GB') {
            return round($value, 1) . ' ' . $unit;
        }
        $value /= 1024;
    }
    return '';
}

/** ISO 时间 → 本地可读日期（解析失败原样返回）。 */
function nice_date(?string $iso): string
{
    if (!$iso) {
        return '';
    }
    $ts = strtotime($iso);
    return $ts ? date('Y-m-d H:i', $ts) . ' UTC' : $iso;
}

$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
$host = $_SERVER['HTTP_HOST'] ?? 'apple.ct.ws';
$base = $scheme . '://' . $host;
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SL 启动器 · 更新服务</title>
<style>
    /* 观感跟随启动器本体：暖色流动渐变 + 淡白玻璃面板（单层玻璃语言） */
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        min-height: 100vh;
        font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
        background: linear-gradient(135deg, #e8853a, #d4547a, #7b4fb8, #e8853a);
        background-size: 300% 300%;
        animation: drift 18s ease-in-out infinite;
        color: #2b2016;
        padding: 40px 16px;
    }
    @keyframes drift {
        0%, 100% { background-position: 0% 20%; }
        50% { background-position: 100% 80%; }
    }
    .wrap { max-width: 720px; margin: 0 auto; }
    h1 { color: #fff; font-size: 34px; margin-bottom: 6px; text-shadow: 0 1px 8px rgba(0,0,0,.18); }
    .sub { color: rgba(255,255,255,.85); margin-bottom: 28px; font-size: 14px; }
    .card {
        background: rgba(255,255,255,.82);
        border: 1px solid rgba(255,255,255,.5);
        border-radius: 18px;
        padding: 26px 28px;
        margin-bottom: 20px;
        box-shadow: 0 12px 34px rgba(60,20,10,.22);
    }
    .version { font-size: 30px; font-weight: 700; letter-spacing: .5px; }
    .meta { color: #8a7566; font-size: 13px; margin-top: 4px; }
    .notes { margin-top: 14px; font-size: 14px; line-height: 1.75; white-space: pre-wrap; word-break: break-word; }
    .btn {
        display: inline-block; margin-top: 18px;
        background: #d4547a; color: #fff; text-decoration: none;
        font-weight: 600; font-size: 15px;
        padding: 11px 26px; border-radius: 12px;
        box-shadow: 0 6px 16px rgba(212,84,122,.4);
    }
    .btn:active { transform: translateY(1px); }
    .btn.secondary { background: rgba(255,255,255,.6); color: #7a4a2c; box-shadow: none; border: 1px solid rgba(0,0,0,.08); }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid rgba(0,0,0,.08); }
    th { color: #8a7566; font-weight: 600; font-size: 12px; }
    td a { color: #b03a5b; font-weight: 600; text-decoration: none; }
    .empty { color: #8a7566; font-size: 14px; line-height: 1.8; }
    code {
        background: rgba(0,0,0,.06); border-radius: 6px;
        padding: 2px 7px; font-size: 12.5px; word-break: break-all;
    }
    .foot { color: rgba(255,255,255,.8); font-size: 12.5px; margin-top: 26px; line-height: 2; }
    .foot code { background: rgba(0,0,0,.18); color: #fff; }
</style>
</head>
<body>
<div class="wrap">
    <h1>SL 启动器</h1>
    <div class="sub">macOS · 自动更新服务（更新源）</div>

    <?php if ($latest === null): ?>
        <div class="card">
            <div class="empty">
                还没有发布任何版本。<br>
                发版方法：把 qwq-&lt;版本&gt;.zip 上传到 <code>updates/</code> 目录，
                然后到 <a href="admin/" style="color:#b03a5b;font-weight:600">管理页</a> 登记版本号即可。
                详见 <code>update-server/README.md</code>。
            </div>
        </div>
    <?php else: ?>
        <?php $asset = first_zip($latest); ?>
        <div class="card">
            <div class="version"><?= htmlspecialchars((string) ($latest['tag_name'] ?? '?'), ENT_QUOTES) ?></div>
            <div class="meta">当前最新版本 · 发布于 <?= htmlspecialchars(nice_date($latest['published_at'] ?? null), ENT_QUOTES) ?></div>
            <?php if (!empty($latest['body'])): ?>
                <div class="notes"><?= htmlspecialchars((string) $latest['body'], ENT_QUOTES) ?></div>
            <?php endif; ?>
            <?php if ($asset !== null): ?>
                <a class="btn" href="<?= htmlspecialchars((string) $asset['browser_download_url'], ENT_QUOTES) ?>">
                    下载 <?= htmlspecialchars((string) ($asset['name'] ?? '安装包'), ENT_QUOTES) ?><?= human_size($asset['size'] ?? null) !== '' ? '（' . human_size($asset['size']) . '）' : '' ?>
                </a>
            <?php endif; ?>
        </div>
    <?php endif; ?>

    <?php if (count($releases) > 1): ?>
        <div class="card">
            <table>
                <tr><th>历史版本</th><th>发布时间</th><th></th></tr>
                <?php foreach (array_slice($releases, 1) as $release): ?>
                    <?php $asset = first_zip($release); ?>
                    <tr>
                        <td><strong><?= htmlspecialchars((string) ($release['tag_name'] ?? '?'), ENT_QUOTES) ?></strong></td>
                        <td><?= htmlspecialchars(nice_date($release['published_at'] ?? null), ENT_QUOTES) ?></td>
                        <td>
                            <?php if ($asset !== null): ?>
                                <a href="<?= htmlspecialchars((string) $asset['browser_download_url'], ENT_QUOTES) ?>">下载</a>
                            <?php endif; ?>
                        </td>
                    </tr>
                <?php endforeach; ?>
            </table>
        </div>
    <?php endif; ?>

    <div class="foot">
        App 检查更新接口（与 GitHub Releases latest 同形，静态文件）：<br>
        <code><?= htmlspecialchars($base, ENT_QUOTES) ?>/api/latest.json</code><br>
        管理入口：<code><?= htmlspecialchars($base, ENT_QUOTES) ?>/admin/</code>
    </div>
</div>
</body>
</html>
