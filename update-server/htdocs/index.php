<?php
/**
 * SL 启动器 · 更新服务 —— 公开页（纯展示，只读 data/releases.json）。
 *
 * 架构约定（零美元档：InfinityFree 免费虚拟主机 = PHP-only / 无数据库 / 无 cron）：
 *   · App 检查更新读的是**静态** /api/latest.json（GitHub releases/latest 同形 JSON，
 *     AppUpdateService.parseLatestRelease 可以零改动解析）——请求路径不跑 PHP；
 *   · App / 网页下载的是**静态** /updates/*.dmg（或 *.zip）——同样不跑 PHP，
 *     服务器支持 HTTP Range（Accept-Ranges: bytes），下载端可并发分块加速；
 *   · PHP 只在 /admin（发版登记页）里执行：把安装包登记成新版本，原子改写
 *     api/latest.json 与 data/releases.json。流程见 update-server/README.md。
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
                <div class="btnrow">
                    <a class="btn" href="<?= htmlspecialchars((string) $asset['browser_download_url'], ENT_QUOTES) ?>">
                        下载 <?= htmlspecialchars((string) ($asset['name'] ?? '安装包'), ENT_QUOTES) ?><?= human_size($asset['size'] ?? null) !== '' ? '（' . human_size($asset['size']) . '）' : '' ?>
                    </a>
                    <button class="btn turbo" type="button" data-url="<?= htmlspecialchars((string) $asset['browser_download_url'], ENT_QUOTES) ?>" data-name="<?= htmlspecialchars((string) ($asset['name'] ?? '安装包'), ENT_QUOTES) ?>">
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

<script>
// ⚡ 多线程下载：服务器静态文件支持 HTTP Range（Accept-Ranges: bytes），
// 并发拉取若干分段再拼装。每段用流式读取逐块累计字节数，
// 进度条是「真实字节数 / 总字节数」，并显示实时速度（MB/s）。
(function () {
    'use strict';

    function humanSize(n) {
        if (!n || n <= 0) return '';
        if (n < 1024) return n + ' B';
        if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
        if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
        return (n / 1073741824).toFixed(2) + ' GB';
    }

    // 流式读取整段响应，每收到一块就回调累计字节数
    async function readStream(resp, onChunk) {
        const reader = resp.body.getReader();
        let got = 0;
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            got += value.byteLength;
            onChunk(got);
        }
        return got;
    }

    // 取总大小 + 确认支持 Range
    async function probe(url) {
        const resp = await fetch(url, { headers: { Range: 'bytes=0-0' }, credentials: 'same-origin' });
        if (!resp.ok && resp.status !== 206) throw new Error('HTTP ' + resp.status);
        let total = 0, supported = false;
        if (resp.status === 206) {
            const m = (resp.headers.get('Content-Range') || '').match(/\/(\d+)$/);
            total = m ? parseInt(m[1], 10) : 0;
            supported = total > 0;
        }
        return { total: total, supported: supported };
    }

    async function start(btn) {
        const url = btn.dataset.url, name = btn.dataset.name;
        const box = btn.parentElement;
        const prog = box.querySelector('.prog');
        const bar = prog.querySelector('i'), label = prog.querySelector('em');
        const orig = btn.textContent;

        btn.disabled = true;
        prog.classList.add('on');
        bar.style.background = '';
        bar.style.width = '0%';
        label.textContent = '连接中…';
        let last = performance.now(), lastBytes = 0, speed = 0;
        const speedTimer = setInterval(function () {
            const now = performance.now();
            const dt = (now - last) / 1000;
            if (dt > 0) {
                speed = (now > 0 && lastBytes > 0) ? (lastBytes / 1048576 / dt) : 0;
                last = now; lastBytes = 0;
            }
        }, 800);

        try {
            const info = await probe(url);
            let buffers;
            if (!info.supported || info.total <= 0) {
                // 不支持 Range：单连接整份拉取
                const resp = await fetch(url, { credentials: 'same-origin' });
                if (!resp.ok) throw new Error('HTTP ' + resp.status);
                const total = info.total || Number(resp.headers.get('Content-Length')) || 0;
                const got = await readStream(resp, function (c) {
                    if (total > 0) {
                        lastBytes = c;
                        const f = c / total;
                        bar.style.width = Math.min(100, f * 100) + '%';
                        label.textContent = Math.round(f * 100) + '% · ' + humanSize(c) + ' / ' + humanSize(total);
                    }
                });
                buffers = [resp]; // 占位，下面用原始 buffer
                // 因为 readStream 已读完，重新取 buffer：
                buffers = [await (await fetch(url, { credentials: 'same-origin' })).arrayBuffer()];
            } else {
                const MB = info.total / 1048576;
                const n = MB < 8 ? 1 : MB < 16 ? 4 : MB < 32 ? 6 : 8;
                if (n === 1) {
                    const resp = await fetch(url, { credentials: 'same-origin' });
                    if (!resp.ok) throw new Error('HTTP ' + resp.status);
                    const got = await readStream(resp, function (c) {
                        lastBytes = c;
                        const f = c / info.total;
                        bar.style.width = Math.min(100, f * 100) + '%';
                        label.textContent = Math.round(f * 100) + '% · ' + humanSize(c) + ' / ' + humanSize(info.total);
                    });
                    buffers = [await (await fetch(url, { credentials: 'same-origin' })).arrayBuffer()];
                } else {
                    // 并发分段：每段独立流式读取，全局进度 = 累计字节 / 总字节
                    const chunk = Math.ceil(info.total / n);
                    const done = new Array(n);
                    let received = 0;
                    const tasks = [];
                    for (let i = 0; i < n; i++) {
                        const s = i * chunk, e = Math.min(s + chunk, info.total) - 1;
                        tasks.push((async () => {
                            const resp = await fetch(url, { headers: { Range: 'bytes=' + s + '-' + e }, credentials: 'same-origin' });
                            if (resp.status !== 206) throw new Error('Range 被拒绝 HTTP ' + resp.status);
                            const parts = [];
                            let segGot = 0;
                            const reader = resp.body.getReader();
                            for (;;) {
                                const r = await reader.read();
                                if (r.done) break;
                                parts.push(r.value);
                                segGot += r.value.byteLength;
                                received += r.value.byteLength;
                                lastBytes += r.value.byteLength;
                                const f = received / info.total;
                                bar.style.width = Math.min(100, f * 100) + '%';
                                label.textContent = Math.round(f * 100) + '% · ' + humanSize(received) + ' / ' + humanSize(info.total);
                            }
                            const buf = new Uint8Array(segGot);
                            let off = 0;
                            for (const p of parts) { buf.set(p, off); off += p.byteLength; }
                            done[i] = buf.buffer;
                        })());
                    }
                    await Promise.all(tasks);
                    buffers = done;
                }
            }
            const blob = new Blob(buffers, { type: 'application/octet-stream' });
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = name;
            document.body.appendChild(a);
            a.click();
            setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 4000);
            clearInterval(speedTimer);
            bar.style.width = '100%';
            label.textContent = '完成 ✓ · ' + humanSize(blob.size);
        } catch (e) {
            clearInterval(speedTimer);
            label.textContent = '失败：' + (e && e.message ? e.message : '未知错误');
            bar.style.background = 'linear-gradient(90deg, #c0392b, #e05d4e)';
        } finally {
            btn.disabled = false;
            btn.textContent = orig;
            // 完成/失败信息停留 6 秒再收起
            setTimeout(function () { prog.classList.remove('on'); }, 6000);
        }
    }

    document.querySelectorAll('.btn.turbo').forEach(function (btn) {
        btn.addEventListener('click', function (e) {
            e.preventDefault();
            start(btn);
        });
    });
})();
</script>
</body>
</html>
