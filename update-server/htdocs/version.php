<?php
/**
 * 版本详情页：?tag=vX.Y.Z —— 与主页同观感，含 普通下载 + 多线程下载。
 * 数据源同主页（data/releases.json，发布流程原子改写）。
 * ⚠️ 版本已从 releases.json 下架/不存在时：显示「已下架」而不是历史列表（用户要求：删了就不显示）。
 */
$DATA_DIR = __DIR__ . '/data';
$releases = [];
if (is_file($DATA_DIR . '/releases.json')) {
    $decoded = json_decode((string) file_get_contents($DATA_DIR . '/releases.json'), true);
    if (is_array($decoded) && isset($decoded['releases']) && is_array($decoded['releases'])) {
        $releases = $decoded['releases'];
    }
}
$tag = isset($_GET['tag']) ? trim((string) $_GET['tag']) : '';
$release = null;
foreach ($releases as $r) {
    if (is_array($r) && ($r['tag_name'] ?? '') === $tag) { $release = $r; break; }
}
function dl_url(array $asset): string
{
    $name = basename((string) ($asset['name'] ?? ''));
    if ($name !== '' && is_file(__DIR__ . '/updates/' . $name)) {
        return 'updates/' . rawurlencode($name);
    }
    return (string) $asset['browser_download_url'];
}
function first_package(array $release): ?array
{
    $assets = array_filter(($release['assets'] ?? []), function ($asset) {
        $name = strtolower((string) ($asset['name'] ?? ''));
        return is_array($asset) && isset($asset['browser_download_url'])
            && (str_ends_with($name, '.dmg') || str_ends_with($name, '.zip'));
    });
    $assets = array_values($assets);
    if ($assets === []) return null;
    usort($assets, function ($a, $b) {
        $rank = function ($asset) { return str_ends_with(strtolower((string) ($asset['name'] ?? '')), '.dmg') ? 0 : 1; };
        return $rank($a) <=> $rank($b);
    });
    return $assets[0] ?? null;
}
function human_size($bytes): string
{
    if (!is_numeric($bytes) || $bytes <= 0) return '';
    if ($bytes < 1024) return $bytes . ' B';
    if ($bytes < 1048576) return ($bytes / 1024) . ' KB';
    if ($bytes < 1073741824) return ($bytes / 1048576) . ' MB';
    return ($bytes / 1073741824) . ' GB';
}
function nice_date(?string $iso): string
{
    if (!$iso) return '';
    $ts = strtotime($iso);
    return $ts ? date('Y-m-d H:i', $ts) . ' UTC' : $iso;
}
$asset = $release ? first_package($release) : null;
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars(($release['tag_name'] ?? '版本') . ' · SL 启动器', ENT_QUOTES) ?></title>
<style>
    :root {
        --bg: #0e1014; --glass: rgba(28, 30, 36, 0.55); --glass-soft: rgba(255,255,255,.04);
        --glass-border: rgba(255,255,255,.1); --glass-border-hi: rgba(255,255,255,.18);
        --text: #eceef2; --muted: #9aa0ab; --faint: #6b7280; --accent: #6cb6ff; --ok: #3ecf8e;
        --radius: 12px; --blur: 22px;
        --font: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Helvetica Neue", sans-serif;
        --mono: ui-monospace, "SF Mono", Menlo, monospace;
        --ease-soft: cubic-bezier(0.4, 0, 0.2, 1);
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { min-height: 100vh; font-family: var(--font); background: var(--bg); color: var(--text);
           padding: 40px 16px; -webkit-font-smoothing: antialiased; overflow-x: hidden; }
    body::before, body::after { content: ''; position: fixed; border-radius: 50%; filter: blur(90px);
        opacity: .35; pointer-events: none; z-index: 0; }
    body::before { width: 520px; height: 520px; top: -140px; left: -80px;
        background: radial-gradient(circle, rgba(255,190,50,.42), transparent 70%);
        animation: drift1 16s var(--ease-soft) infinite alternate; }
    body::after { width: 460px; height: 460px; bottom: -120px; right: -60px;
        background: radial-gradient(circle, rgba(108,182,255,.30), transparent 70%);
        animation: drift2 20s var(--ease-soft) infinite alternate; }
    @keyframes drift1 { from { transform: translate(0,0) scale(1); } to { transform: translate(6%,8%) scale(1.12); } }
    @keyframes drift2 { from { transform: translate(0,0) scale(1); } to { transform: translate(-5%,-7%) scale(1.1); } }
    .wrap { position: relative; z-index: 1; max-width: 720px; margin: 0 auto; }
    .back { color: var(--muted); font-size: 14px; text-decoration: none; display: inline-block; margin-bottom: 18px; }
    .back:hover { color: var(--accent); }
    h1 { color: var(--text); font-size: 30px; margin-bottom: 6px; letter-spacing: -.01em; }
    .sub { color: var(--muted); margin-bottom: 28px; font-size: 14px; }
    .card { background: var(--glass); border: 1px solid var(--glass-border); border-radius: 18px;
            padding: 26px 28px; margin-bottom: 20px;
            backdrop-filter: blur(var(--blur)) saturate(1.35); -webkit-backdrop-filter: blur(var(--blur)) saturate(1.35);
            box-shadow: inset 0 1px 0 rgba(255,255,255,.55), 0 12px 34px rgba(60,20,10,.22); }
    .version { font-size: 30px; font-weight: 700; letter-spacing: .5px; }
    .meta { color: var(--faint); font-size: 13px; margin-top: 4px; }
    .notes { margin-top: 14px; font-size: 14px; line-height: 1.75; white-space: pre-wrap; word-break: break-word; }
    .btn { display: inline-block; margin-top: 18px; border-radius: var(--radius); text-decoration: none;
           font-weight: 600; font-size: 15px; padding: 11px 26px; cursor: pointer; font-family: inherit;
           background: var(--glass-soft); color: var(--text); border: 1px solid var(--glass-border); }
    .btn.primary { background: linear-gradient(180deg, rgba(108,182,255,.24), rgba(108,182,255,.13));
           color: var(--accent); border: 1px solid rgba(108,182,255,.38);
           box-shadow: 0 6px 18px rgba(108,182,255,.18); }
    .btn.turbo { background: linear-gradient(180deg, rgba(62,207,142,.24), rgba(62,207,142,.13));
           color: var(--ok); border: 1px solid rgba(62,207,142,.38);
           box-shadow: 0 6px 18px rgba(62,207,142,.18); }
    .btn:active { transform: translateY(1px); }
    .btnrow { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .prog { flex: 1 1 100%; min-width: 220px; height: 22px; margin-top: 6px; display: none;
            background: rgba(255,255,255,.06); border: 1px solid var(--glass-border);
            border-radius: 11px; overflow: hidden; position: relative; }
    .prog.on { display: block; }
    .prog > i { display: block; height: 100%; width: 0%; border-radius: 11px;
                background: linear-gradient(90deg, var(--ok), #7ff0b0); transition: width .25s ease; }
    .prog > em { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
                 font-style: normal; font-size: 12px; color: var(--text); font-weight: 600; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid var(--glass-border); }
    th { color: var(--faint); font-weight: 600; font-size: 12px; }
    td a { color: var(--accent); font-weight: 600; text-decoration: none; }
    td a.cur { color: var(--text); font-weight: 700; }
    .empty { color: var(--muted); font-size: 14px; line-height: 1.8; }
    .foot { color: var(--faint); font-size: 12.5px; margin-top: 26px; line-height: 2; }
</style>
</head>
<body>
<div class="wrap">
    <a class="back" href="index.php">← 返回下载主页</a>
<?php if ($release === null): ?>
    <div class="card"><div class="empty">该版本不存在或已下架。<br><a href="index.php">返回下载主页</a></div></div>
<?php elseif ($asset === null): ?>
    <div class="card"><div class="empty">该版本没有提供安装包。</div></div>
<?php else: ?>
    <?php $isLatest = (count($releases) > 0 && $releases[0]['tag_name'] === ($release['tag_name'] ?? '')); ?>
    <h1><?= htmlspecialchars((string) ($release['tag_name'] ?? '?'), ENT_QUOTES) ?></h1>
    <div class="sub"><?= $isLatest ? '当前最新版本' : '历史版本' ?> · 发布于 <?= htmlspecialchars(nice_date($release['published_at'] ?? null), ENT_QUOTES) ?></div>
    <div class="card">
        <div class="version"><?= htmlspecialchars((string) ($release['tag_name'] ?? '?'), ENT_QUOTES) ?></div>
        <div class="meta">发布于 <?= htmlspecialchars(nice_date($release['published_at'] ?? null), ENT_QUOTES) ?></div>
        <?php if (!empty($release['body'])): ?>
            <div class="notes"><?= htmlspecialchars((string) $release['body'], ENT_QUOTES) ?></div>
        <?php endif; ?>
        <div class="btnrow">
            <a class="btn primary" href="<?= htmlspecialchars(dl_url($asset), ENT_QUOTES) ?>">
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
    </div>
<?php endif; ?>

    <div class="card">
        <table>
            <tr><th>全部版本</th><th>发布时间</th></tr>
        <?php foreach ($releases as $r): ?>
            <?php $t = (string) ($r['tag_name'] ?? '?'); ?>
            <tr>
                <td>
                    <?php if ($t === $tag): ?>
                        <strong><?= htmlspecialchars($t, ENT_QUOTES) ?>（当前）</strong>
                    <?php else: ?>
                        <a href="version.php?tag=<?= htmlspecialchars($t, ENT_QUOTES) ?>"><?= htmlspecialchars($t, ENT_QUOTES) ?></a>
                    <?php endif; ?>
                </td>
                <td><?= htmlspecialchars(nice_date($r['published_at'] ?? null), ENT_QUOTES) ?></td>
            </tr>
        <?php endforeach; ?>
        </table>
    </div>

    <div class="foot">App 检查更新接口：<code><?= htmlspecialchars('https://apple.ct.ws/api/latest.php', ENT_QUOTES) ?></code></div>
</div>

<script>
/* ⚡ 多线程下载：与主页同款 —— 并行 Range 分块（同源直连），失败自动降级
   单连接，再失败交给浏览器下载器；任何一步都不让用户拿到裸错误。 */
(function () {
    'use strict';
    function humanSize(n) {
        if (!n || n <= 0) return '';
        if (n < 1024) return n + ' B';
        if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
        if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
        return (n / 1073741824).toFixed(2) + ' GB';
    }
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
    function handOff(url) {
        var a = document.createElement('a');
        a.href = url; a.rel = 'noopener';
        document.body.appendChild(a); a.click();
        setTimeout(function () { a.remove(); }, 1500);
    }
    function probe(url) {
        return fetch(url, { method: 'HEAD', credentials: 'same-origin' }).then(function (r) {
            if (!r.ok) throw new Error('HTTP ' + r.status);
            var total = parseInt(r.headers.get('Content-Length') || '0', 10);
            var ar = (r.headers.get('Accept-Ranges') || '').toLowerCase();
            if (total > 0) return { total: total, supported: ar === 'bytes' };
            throw new Error('无 Content-Length');
        }).catch(function () {
            return fetch(url, { headers: { Range: 'bytes=0-0' }, credentials: 'same-origin' }).then(function (resp) {
                if (!resp.ok && resp.status !== 206) throw new Error('HTTP ' + resp.status);
                var total = 0, supported = false;
                if (resp.status === 206) {
                    var m = (resp.headers.get('Content-Range') || '').match(/\/(\d+)$/);
                    total = m ? parseInt(m[1], 10) : 0; supported = total > 0;
                }
                return { total: total, supported: supported };
            });
        });
    }
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
                parts.push(r.value); got += r.value.byteLength;
                if (onBytes) onBytes(r.value.byteLength);
                return pump();
            });
        }
        return pump();
    }
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
                    parts.push(r.value); got += r.value.byteLength;
                    if (onBytes) onBytes(r.value.byteLength);
                    return pump();
                });
            }
            return pump();
        });
    }
    function fetchChunk(url, from, to, onBytes) {
        return fetch(url, { credentials: 'same-origin', headers: { Range: 'bytes=' + from + '-' + to } })
            .then(function (resp) {
                if (resp.status !== 206) throw new Error('Range 被拒绝 HTTP ' + resp.status);
                return readBody(resp, onBytes);
            });
    }
    function saveBlob(parts, name) {
        var blob = new Blob(parts, { type: 'application/octet-stream' });
        var u = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = u; a.download = name;
        document.body.appendChild(a); a.click();
        setTimeout(function () { URL.revokeObjectURL(u); a.remove(); }, 60000);
        return blob.size;
    }
    function start(btn) {
        var url = btn.dataset.url, fallback = btn.dataset.fallback || url, name = btn.dataset.name || '安装包';
        var box = btn.parentElement, prog = box.querySelector('.prog');
        var bar = prog.querySelector('i'), label = prog.querySelector('em');
        var orig = btn.textContent;
        btn.disabled = true; prog.classList.add('on');
        bar.style.background = ''; bar.style.width = '0%'; label.textContent = '连接中…';
        var total = 0, received = 0, lastBytes = 0, speed = 0, t0 = Date.now(), lastT = t0;
        var timer = setInterval(function () {
            var now = Date.now(), dt = (now - lastT) / 1000;
            if (dt <= 0) return;
            speed = lastBytes / 1048576 / dt; lastBytes = 0; lastT = now;
            if (total > 0) label.textContent = Math.round(received / total * 100) + '% · '
                + humanSize(received) + ' / ' + humanSize(total)
                + (speed > 0.01 ? ' · ' + speed.toFixed(1) + ' MB/s' : '');
        }, 600);
        function tick(bytes) {
            received += bytes; lastBytes += bytes;
            if (total > 0) {
                bar.style.width = Math.min(100, received / total * 100) + '%';
                label.textContent = Math.round(received / total * 100) + '% · '
                    + humanSize(received) + ' / ' + humanSize(total)
                    + (speed > 0.01 ? ' · ' + speed.toFixed(1) + ' MB/s' : '');
            } else label.textContent = '已下载 ' + humanSize(received);
        }
        function reset() {
            btn.disabled = false; btn.textContent = orig;
            setTimeout(function () { prog.classList.remove('on'); }, 12000);
        }
        function finish() {
            clearInterval(timer); bar.style.width = '100%';
            label.textContent = '完成 ✓ · ' + humanSize(received) + ' · 用时 ' + ((Date.now() - t0) / 1000).toFixed(1) + 's';
            reset();
        }
        function degrade(reason) {
            clearInterval(timer);
            bar.style.background = ''; bar.style.width = '100%';
            label.textContent = '已切换为浏览器直接下载（' + reason + '）';
            handOff(fallback); reset();
        }
        function run() {
            if (!window.fetch || typeof Blob === 'undefined' || !(window.URL && URL.createObjectURL)) { degrade('浏览器不支持分块下载'); return; }
            probe(url).then(function (info) {
                total = info.total || 0;
                var mb = total / 1048576;
                var n = (!info.supported || total <= 0) ? 1
                    : (mb < 8 ? 1 : mb < 16 ? 4 : mb < 32 ? 6 : 8);
                if (n <= 1) {
                    return fetchWhole(url, total, tick).then(function (buf) {
                        received = buf.byteLength; saveBlob([buf], name); finish();
                    });
                }
                var chunk = Math.ceil(total / n), parts = new Array(n), tasks = [];
                for (var i = 0; i < n; i++) {
                    (function (idx) {
                        var from = idx * chunk, to = Math.min(from + chunk, total) - 1;
                        tasks.push(fetchChunk(url, from, to, tick).then(function (buf) { parts[idx] = buf; }));
                    })(i);
                }
                return Promise.all(tasks).then(function () { saveBlob(parts, name); finish(); });
            }).catch(function () { degrade('分块不可用'); });
        }
        try { run(); } catch (e) { degrade('脚本异常'); }
    }
    var btns = document.querySelectorAll('.btn.turbo');
    for (var i = 0; i < btns.length; i++) {
        btns[i].addEventListener('click', function (e) { e.preventDefault(); start(this); });
    }
})();
</script>
</body>
</html>
