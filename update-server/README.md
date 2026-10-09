# SL 启动器 · 更新服务（apple.ct.ws）

零美元方案：部署在免费 PHP 虚拟主机（InfinityFree 免费档，PHP-only、无数据库、
无 SSH、无 cron）。发布即同步（GitHub Actions 触发），App 手动检查更新时读到
的是已经就位的最新版本与安装包，全程无 cron 外呼。

## 目录结构（apple.ct.ws/htdocs/ 即网站根目录）

```
htdocs/
├── index.php            公开页：最新版本 / 更新说明 / 下载按钮 / 历史版本
├── .htaccess            关目录列表 + 缓存策略
├── admin/index.php      管理页（网页兜底）：登录 → 选 updates/ 里已有安装包 → 发布
├── publish.php          发布入口：key 鉴权后调 publish_core.php 的同步逻辑
├── publish_core.php     共享发布/读写实现（load_releases / atomic_write / …）
├── config.secret.php    ⚠️ 部署机密：管理密码/发布 key 的盐与哈希（绝不提交 git）
├── api/latest.php       App 检查更新端点（原样返回 api/latest.json，同形 GitHub）
├── api/latest.json      ← 实际版本数据（Actions 同步时原子改写）
├── data/releases.json   ← 版本档案（公开页读）
└── updates/             ← 安装包 dmg（zip 回退）静态分发，支持 HTTP Range
```

## 部署（一次性，约 5 分钟）

1. 主机控制面板把域名 `apple.ct.ws` 绑到站点（或主机就是送的这个域名）。
2. 用 FTP（InfinityFree 免费档只给 FTP，账号在控制面板里看）把 `htdocs/` 里的
   **全部内容**传到网站根目录（`apple.ct.ws/htdocs`）。
3. **配置机密**：`config.secret.php` 不在 git 里，部署时手动生成：
   ```bash
   php -r '
     $salt = bin2hex(random_bytes(32));
     $key  = bin2hex(random_bytes(32));
     echo "admin_salt: $salt\n";
     echo "admin_hash: " . hash("sha256", $salt . "你的管理密码") . "\n";
     echo "publish_key: $key\n";
     echo "key_hash: " . hash("sha256", $key) . "\n";
   '
   ```
   把结果写进服务器上的 `config.secret.php`（格式见文件内注释）。
4. 打开 `https://apple.ct.ws/` 应看到版本空态页（或已发布的版本）。

## 发版（主路径自动，另有手动兜底）

### A. 发布即自动同步（主路径，零手工）

GitHub Actions 的 `release.yml` 在每次 Release（tag `v*`）发布时：

1. 构建 `qwq-<版本>.dmg` 并打成 GitHub Release（标题自动带「(Beta)」）；
2. `sync-server` job 求解 InfinityFree 的 slowAES 挑战页 → 用发布 key 调
   `https://apple.ct.ws/publish.php?key=<KEY>`；
3. publish.php 里 `sync_from_github()` 拉最新 release → 下载 dmg 到
   `updates/` → 原子改写 `api/latest.json` + `data/releases.json`。全自动。

本地想手动复查同一流程：

```bash
bash publish.sh     # 见仓库里 update-server/publish.sh（key 在文件顶部改）
```

### B. 手动上传（管理页兜底）

1. 文件管理器/FTP 把 `qwq-<版本>.dmg`（或 zip）传到 `updates/`；
2. 打开 `https://apple.ct.ws/admin/` → 用管理密码登录 → 选安装包、填版本号、
   填更新说明 → 「发布」。

App 端无需任何代码改动：`api/latest.php` 返回的 JSON 与 GitHub
`releases/latest` 同形（`tag_name` / `body` / `assets[].browser_download_url`），
把 `AppUpdateService.latestReleaseAPI` 指到
`https://apple.ct.ws/api/latest.php` 即可切换更新源（见下）。

## 切换 App 更新源（软件侧，一行）

`qwq/SLCore/Update/AppUpdateService.swift` 里：

```swift
private static let latestReleaseAPI =
    "https://apple.ct.ws/api/latest.php"
```

> GitHub Releases 与本服务也可以并存（例如先都留着，观察免费主机稳定性），
> App 只认一个地址，切换即一行。

## 设计备注

- **请求路径几乎全静态**：检查更新（latest.php 读本地 JSON）与下载（dmg/zip）
  都不主动外呼 GitHub——免费主机的 PHP 进程数/执行限制碰不到外呼链路，且
  下载走静态文件 + HTTP Range，App 端可并发分块加速。
- **无数据库**：版本档案是两个 JSON 文件，发布逻辑用「写临时文件 + rename」
  原子改写，读方永远不会读到半截 JSON。
- **同形 GitHub**：App 的解析端（`parseLatestRelease`）零改动兼容。
- **缓存**：`.htaccess` 里 json 不缓存、安装包缓存 1 小时，发布即刻生效。
- 历史列表保留最近 10 个版本；被移除的版本只是不再出现在 latest.json，
  安装包文件仍在 `updates/` 可供手动下载（FTP 可删）。
