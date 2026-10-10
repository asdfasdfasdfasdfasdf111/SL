<?php
/**
 * SL 启动器 · 更新服务 —— 公开页（纯展示，只读 data/releases.json）。
 *
 * 架构约定（零美元档：InfinityFree 免费虚拟主机 = PHP-only / 无数据库 / 无 cron）：
 *   · App 检查更新读的是**静态** /api/latest.json（GitHub releases/latest 同形 JSON，
 *     AppUpdateService.parseLatestRelease 可以零改动解析）——请求路径不跑 PHP；
 *   · App / 网页下载的是**静态** /updates/*.dmg（或 *.zip）——同样不跑 PHP，
 *     服务器支持 HTTP Range（Accept-Ranges: bytes），下载端可并发分块加速；
 *   · PHP 只在发布入口（publish.php）里执行：GitHub Actions 在 Release 发布时
 *     自动触发，把最新安装包同步到 updates/ 并原子改写 api/latest.json 与
 *     data/releases.json。手动兜底用 update-server/publish.sh。
 *
 * 本页面在任何数据都缺失时也要能渲染（刚部署、还没发过版的形态）。
 * 页面下载按钮 = 前端多线程下载（并发 Range 分块 → 拼装 → 触发浏览器保存），
 * 免费主机单连接慢，多连接可成倍提速；浏览器原生下载另留普通链接兜底。
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

/**
 * 下载地址：**同源镜像优先**。
 *
 * GitHub 的 browser_download_url 是跨域地址，而带 Range 头的跨域 fetch 会触发 CORS 预检；
 * QQ 内置浏览器（X5/WKWebView 套壳）会直接掐掉这类跨站请求，前端只能拿到
 * "Failed to fetch"（用户实测；Safari / Chrome 放行）。同步任务已把安装包落到 updates/，
 * 所以优先给同源地址：同源无预检、Range 也照常工作。
 */
function dl_url(array $asset): string
{
    $name = basename((string) ($asset['name'] ?? ''));
    if ($name !== '' && is_file(__DIR__ . '/updates/' . $name)) {
        return 'updates/' . rawurlencode($name);
    }
    return (string) $asset['browser_download_url'];
}


/** 取某条记录的第一个安装包资产（dmg 优先，zip 回退）；没有则 null。 */
function first_package(array $release): ?array
{
    $assets = array_filter(($release['assets'] ?? []), function ($asset) {
        $name = strtolower((string) ($asset['name'] ?? ''));
        return is_array($asset) && isset($asset['browser_download_url'])
            && (str_ends_with($name, '.dmg') || str_ends_with($name, '.zip'));
    });
    $assets = array_values($assets);
    if ($assets === []) {
        return null;
    }
    usort($assets, function ($a, $b) {
        $rank = function ($asset) {
            return str_ends_with(strtolower((string) ($asset['name'] ?? '')), '.dmg') ? 0 : 1;
        };
        return $rank($a) <=> $rank($b);
    });
    return $assets[0];
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
        border: none; cursor: pointer; font-family: inherit;
    }
    .btn:active { transform: translateY(1px); }
    .btn.secondary { background: rgba(255,255,255,.6); color: #7a4a2c; box-shadow: none; border: 1px solid rgba(0,0,0,.08); }
    .btn.turbo { background: #2e9e6b; box-shadow: 0 6px 16px rgba(46,158,107,.35); }
    .btn.turbo:disabled { background: #9bb8aa; cursor: wait; box-shadow: none; }
    .btnrow { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .prog { flex: 1 1 100%; min-width: 220px; height: 22px; margin-top: 6px; display: none;
            background: rgba(0,0,0,.08); border-radius: 11px; overflow: hidden; position: relative; }
    .prog.on { display: block; }
    .prog > i { display: block; height: 100%; width: 0%; border-radius: 11px;
                background: linear-gradient(90deg, #2e9e6b, #4cc07f);
                transition: width .25s ease; }
    .prog > em { position: absolute; inset: 0; display: flex; align-items: center;
                 justify-content: center; font-style: normal; font-size: 12px;
                 color: #3d3228; font-weight: 600; text-shadow: 0 1px 0 rgba(255,255,255,.4); }
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
                发版方法：在 GitHub 仓库创建 <code>v*</code> tag（如 <code>v1.6.1</code>），
                自动构建 dmg 并同步到本站；也可用 <code>update-server/publish.sh</code> 手动发布。
            </div>
        </div>
    <?php else: ?>
        <?php $asset = first_package($latest); ?>
        <div class="card">
            <div class="version"><?= htmlspecialchars((string) ($latest['tag_name'] ?? '?'), ENT_QUOTES) ?></div>
            <div class="meta">当前最新版本 · 发布于 <?= htmlspecialchars(nice_date($latest['published_at'] ?? null), ENT_QUOTES) ?></div>
            <?php if (!empty($latest['body'])): ?>
                <div class="notes"><?= htmlspecialchars((string) $latest['body'], ENT_QUOTES) ?></div>
            <?php endif; ?>
            <?php if ($asset !== null): ?>
                <div class="btnrow">
                    <a class="btn" href="<?= htmlspecialchars(dl_url($asset), ENT_QUOTES) ?>">
                        下载 <?= htmlspecialchars((string) ($asset['name'] ?? '安装包'), ENT_QUOTES) ?><?= human_size($asset['size'] ?? null) !== '' ? '（' . human_size($asset['size']) . '）' : '' ?>
                    </a>
                    <button class="btn turbo" type="button"
                            data-url="<?= htmlspecialchars(dl_url($asset), ENT_QUOTES) ?>"
                            data-fallback="<?= htmlspecialchars((string) $asset['browser_download_url'], ENT_QUOTES) ?>"
                            data-name="<?= htmlspecialchars((string) ($asset['name'] ?? '安装包'), ENT_QUOTES) ?>">
                        ⚡ 多线程下载（推荐）
                    </button>
                    <div class="prog"><i></i><em>0%</em></div>
                </div>
            <?php endif; ?>
        </div>
    <?php endif; ?>

    <?php if (count($releases) > 1): ?>
        <div class="card">
            <table>
                <tr><th>历史版本</th><th>发布时间</th><th></th></tr>
                <?php foreach (array_slice($releases, 1) as $release): ?>
                    <?php $asset = first_package($release); ?>
                    <tr>
                        <td><strong><?= htmlspecialchars((string) ($release['tag_name'] ?? '?'), ENT_QUOTES) ?></strong></td>
                        <td><?= htmlspecialchars(nice_date($release['published_at'] ?? null), ENT_QUOTES) ?></td>
                        <td>
                            <?php if ($asset !== null): ?>
                                <a href="<?= htmlspecialchars(dl_url($asset), ENT_QUOTES) ?>">下载</a>
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

<script>
// ⚡ 多线程下载：同源静态文件支持 HTTP Range（Accept-Ranges: bytes），并发分段再拼装。
//
// 兼容策略（关键：任何一步失败都不能让用户拿不到文件）：
//   ① 并行 Range 分块（需要 Streams/ArrayBuffer；**同源**请求不触发 CORS 预检）
//   ② 单连接整份拉取（不支持 Range，或分块路径出错）
//   ③ 交还浏览器自己的下载器（连 fetch 都不行时——QQ 内置浏览器会拦跨站 fetch，
//      这正是之前报 "Failed to fetch" 的场景）
(function () {
    'use strict';

    function humanSize(n) {
        if (!n || n <= 0) return '';
        if (n < 1024) return n + ' B';
        if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
        if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
        return (n / 1073741824).toFixed(2) + ' GB';
    }

    // 探测运行环境：老内核（X5/WKWebView 套壳）可能没有 Streams
    var streamSupport = null;
    function hasStreams() {
        if (streamSupport !== null) return streamSupport;
        try {
            streamSupport = !!(window.fetch && window.Blob && window.URL && URL.createObjectURL
                && typeof Response !== 'undefined' && !!Response.prototype.arrayBuffer
                && !!(new Response('')).body
                && typeof (new Response('')).body.getReader === 'function');
        } catch (e) { streamSupport = false; }
        return streamSupport;
    }

    // ③ 兜底：把下载交还浏览器（QQ 内置浏览器会转到它自己的下载器）
    function handOff(url) {
        var a = document.createElement('a');
        a.href = url;
        a.rel = 'noopener';
        document.body.appendChild(a);
        a.click();
        setTimeout(function () { a.remove(); }, 1500);
    }

    function probe(url) {
        // 先 HEAD：同源简单请求，省流量，直接拿总大小与 Range 支持
        return fetch(url, { method: 'HEAD', credentials: 'same-origin' }).then(function (r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            var total = parseInt(r.headers.get('Content-Length') || '0', 10);
            var ar = (r.headers.get('Accept-Ranges') || '').toLowerCase();
            if (total > 0) return { total: total, supported: ar === 'bytes' };
            throw new Error('无 Content-Length');
        }).catch(function () {
            // 个别主机 HEAD 405：退回 Range 探测
            return fetch(url, { headers: { Range: 'bytes=0-0' }, credentials: 'same-origin' })
                .then(function (resp) {
                    if (!resp.ok && resp.status !== 206) throw new Error('HTTP ' + resp.status);
                    var total = 0, supported = false;
                    if (resp.status === 206) {
                        var m = (resp.headers.get('Content-Range') || '').match(/\/(\d+)$/);
                        total = m ? parseInt(m[1], 10) : 0;
                        supported = total > 0;
                    }
                    return { total: total, supported: supported };
                });
        });
    }

    // 读一段响应为 ArrayBuffer（有 Streams 就边读边报进度）
    function readBody(resp, onBytes) {
        if (!hasStreams()) return resp.arrayBuffer();
        var reader = resp.body.getReader(), parts = [], got = 0;
        function pump() {
            return reader.read().then(function (r) {
                if (r.done) {
                    var buf = new Uint8Array(got), off = 0;
                    for (var i = 0; i < parts.length; i++) { buf.set(parts[i], off); off += parts[i].byteLength; }
                    return buf.buffer;
                }
                parts.push(r.value);
                got += r.value.byteLength;
                if (onBytes) onBytes(r.value.byteLength);
                return pump();
            });
        }
        return pump();
    }

    // ② 单连接整份拉取（只请求一次——旧版这里会重复下载一遍）
    function fetchWhole(url, knownTotal, onBytes) {
        return fetch(url, { credentials: 'same-origin' }).then(function (resp) {
            if (!resp.ok) throw new Error('HTTP ' + resp.status);
            var size = knownTotal || Number(resp.headers.get('Content-Length')) || 0;
            if (!hasStreams()) return resp.arrayBuffer();
            var reader = resp.body.getReader(), parts = [], got = 0;
            function pump() {
                return reader.read().then(function (r) {
                    if (r.done) {
                        var buf = new Uint8Array(got), off = 0;
                        for (var i = 0; i < parts.length; i++) { buf.set(parts[i], off); off += parts[i].byteLength; }
                        return buf.buffer;
                    }
                    parts.push(r.value);
                    got += r.value.byteLength;
                    if (onBytes) onBytes(r.value.byteLength);
                    return pump();
                });
            }
            return pump();
        });
    }

    function fetchChunk(url, from, to, onBytes) {
        return fetch(url, { headers: { Range: 'bytes=' + from + '-' + to }, credentials: 'same-origin' })
            .then(function (resp) {
                if (resp.status !== 206) throw new Error('Range 被拒绝 HTTP ' + resp.status);
                return readBody(resp, onBytes);
            });
    }

    function saveBlob(parts, name) {
        var blob = new Blob(parts, { type: 'application/octet-stream' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = name;
        document.body.appendChild(a);
        a.click();
        setTimeout(function () { URL.revokeObjectURL(url); a.remove(); }, 60000);
        return blob.size;
    }

    function start(btn) {
        var url = btn.dataset.url;
        var fallback = btn.dataset.fallback || url;
        var name = btn.dataset.name || '安装包';
        var box = btn.parentElement;
        var prog = box.querySelector('.prog');
        var bar = prog.querySelector('i'), label = prog.querySelector('em');
        var orig = btn.textContent;

        btn.disabled = true;
        prog.classList.add('on');
        bar.style.background = '';
        bar.style.width = '0%';
        label.textContent = '连接中…';

        var total = 0, received = 0, lastBytes = 0, speed = 0;
        var t0 = Date.now(), lastT = t0;
        var timer = setInterval(function () {
            var now = Date.now(), dt = (now - lastT) / 1000;
            if (dt <= 0) return;
            speed = lastBytes / 1048576 / dt;
            lastBytes = 0; lastT = now;
            if (total > 0) {
                label.textContent = Math.round(received / total * 100) + '% · '
                    + humanSize(received) + ' / ' + humanSize(total)
                    + (speed > 0.01 ? ' · ' + speed.toFixed(1) + ' MB/s' : '');
            }
        }, 600);

        function tick(bytes) {
            received += bytes;
            lastBytes += bytes;
            if (total > 0) {
                bar.style.width = Math.min(100, received / total * 100) + '%';
                label.textContent = Math.round(received / total * 100) + '% · '
                    + humanSize(received) + ' / ' + humanSize(total)
                    + (speed > 0.01 ? ' · ' + speed.toFixed(1) + ' MB/s' : '');
            } else {
                label.textContent = '已下载 ' + humanSize(received);
            }
        }

        // 收尾：恢复按钮、延迟收起进度条（下载中不恢复，避免重复点击）
        function reset() {
            btn.disabled = false;
            btn.textContent = orig;
            setTimeout(function () { prog.classList.remove('on'); }, 12000);
        }

        function finish() {
            clearInterval(timer);
            bar.style.width = '100%';
            label.textContent = '完成 ✓ · ' + humanSize(received)
                + ' · 用时 ' + ((Date.now() - t0) / 1000).toFixed(1) + 's';
            reset();
        }

        // ③ 最终兜底：直接交给浏览器下载（不再抛 "Failed to fetch"）
        function degrade(reason) {
            clearInterval(timer);
            bar.style.background = '';
            bar.style.width = '100%';
            label.textContent = '已切换为浏览器直接下载（' + reason + '）';
            handOff(fallback);
            reset();
        }

        function run() {
            if (!window.fetch || typeof Blob === 'undefined' || !(window.URL && URL.createObjectURL)) {
                degrade('浏览器不支持分块下载');
                return;
            }
            probe(url).then(function (info) {
                total = info.total || 0;
                var mb = total / 1048576;
                var n = (!info.supported || total <= 0) ? 1
                    : (mb < 8 ? 1 : mb < 16 ? 4 : mb < 32 ? 6 : 8);
                if (n <= 1) {
                    return fetchWhole(url, total, tick).then(function (buf) {
                        received = buf.byteLength;
                        saveBlob([buf], name);
                        finish();
                    });
                }
                var chunk = Math.ceil(total / n);
                var parts = new Array(n);
                var tasks = [];
                for (var i = 0; i < n; i++) {
                    (function (idx) {
                        var from = idx * chunk;
                        var to = Math.min(from + chunk, total) - 1;
                        tasks.push(fetchChunk(url, from, to, tick).then(function (buf) { parts[idx] = buf; }));
                    })(i);
                }
                return Promise.all(tasks).then(function () {
                    saveBlob(parts, name);
                    finish();
                });
            }).catch(function () {
                // ① / ② 都失败 → 退到 ③：清掉半截进度，改由浏览器下载
                degrade('分块不可用');
            });
        }

        try { run(); } catch (e) { degrade('脚本异常'); }
    }

    var btns = document.querySelectorAll('.btn.turbo');
    for (var i = 0; i < btns.length; i++) {
        btns[i].addEventListener('click', function (e) {
            e.preventDefault();
            start(this);
        });
    }
})();
</script>
</body>
</html>
