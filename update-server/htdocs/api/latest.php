<?php
/**
 * SL 启动器 · 更新服务 —— App 检查更新端点（纯本地返回版）
 *
 * 服务器**不主动查 GitHub**：网站侧由 GitHub Actions 定时任务（每小时）触发
 * publish.php，把最新 release 的安装包提前同步到本地 updates/ 并改写本 JSON。
 * 因此本端点只做一件事：把已同步好的 latest.json 原样返回（毫秒级、无外呼）。
 *
 * App 打开时不检查更新；用户手动点「检查更新」时访问这里，读到的就是
 * 服务器端一小时前已就位的最新版本与安装包（本地 URL → 快速下载）。
 *
 * 响应始终保持 GitHub releases/latest 同形 —— App 解析端零改动。
 */

declare(strict_types=1);

define('SL_ENTRY', 1);

header('Content-Type: application/json; charset=utf-8');

$localJson = dirname(__DIR__) . '/api/latest.json';
if (is_file($localJson)) {
    echo file_get_contents($localJson);
    exit;
}
http_response_code(404);
echo json_encode(['error' => 'no release synced yet'], JSON_UNESCAPED_SLASHES);