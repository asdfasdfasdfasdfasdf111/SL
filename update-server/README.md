# SL 启动器 · 更新服务（apple.ct.ws）

零美元方案：部署在免费 PHP 虚拟主机（InfinityFree 免费档，PHP-only、无数据库、
无 SSH、无 cron），静态文件 + 单个管理页即可支撑全部自动更新流量。

## 目录结构（htdocs/ 即网站根目录）

```
htdocs/
├── index.php            公开页：最新版本 / 更新说明 / 下载按钮 / 历史版本
├── .htaccess            关目录列表 + 缓存策略
├── admin/index.php      管理页：手动发版登记（登录 → 选 zip → 发布）
├── publish.php          一键发版：服务器自动从 GitHub 拉最新 Release（key 鉴权）
├── config.secret.php    ⚠️ 部署机密：管理密码/发布 key 的盐与哈希（绝不提交 git）
├── api/latest.json      ← App 检查更新读这里（GitHub 同形 JSON）
├── data/releases.json   ← 版本档案（公开页读）
└── updates/             ← 安装包 zip 存放处（静态分发）
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

## 发版（两条路，任选）

### A. 一键发布（推荐）：服务器从 GitHub 自动同步

CI 把 zip 传到 GitHub Release 后，本地跑一条命令：

```bash
bash publish.sh     # 见仓库里 update-server/publish.sh（key 在文件顶部改）
```

`publish.php` 会调 GitHub Releases API 拉最新 release → 下载 zip 到
`updates/` → 原子改写 `api/latest.json` + `data/releases.json`。全自动。

### B. 手动上传（管理页）

1. 文件管理器/FTP 把 `qwq-<版本>.zip` 传到 `updates/`；
2. 打开 `https://apple.ct.ws/admin/` → 用管理密码登录 → 选 zip、填版本号、
   填更新说明 → 「发布」。

App 端无需任何代码改动：`api/latest.json` 与 GitHub `releases/latest` 同形
（`tag_name` / `body` / `assets[].browser_download_url`），把
`AppUpdateService.latestReleaseAPI` 指到
`https://apple.ct.ws/api/latest.json` 即可切换更新源（见下）。

## 切换 App 更新源（软件侧，一行）

`qwq/SLCore/Update/AppUpdateService.swift` 里：

```swift
private static let latestReleaseAPI =
    "https://apple.ct.ws/api/latest.json"
```

> GitHub Releases 与本服务也可以并存（例如先都留着，观察免费主机稳定性），
> App 只认一个地址，切换即一行。

## 设计备注

- **请求路径全是静态**：检查更新（latest.json）与下载（zip）都不跑 PHP——
  免费主机的 PHP 进程数/执行限制碰不到这条链路，也扛得住并发。
- **无数据库**：版本档案是两个 JSON 文件，管理页用「写临时文件 + rename」
  原子改写，读方永远不会读到半截 JSON。
- **同形 GitHub**：App 的解析端（`parseLatestRelease`）零改动兼容。
- **缓存**：`.htaccess` 里 json 不缓存、zip 缓存 1 小时，发布即刻生效。
- 管理页保留最近 10 个版本在列表里；被移除的版本只是不再出现在 latest.json，
  zip 文件仍在 `updates/` 可供手动下载（FTP 可删）。
