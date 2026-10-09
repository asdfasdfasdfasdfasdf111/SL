# SL — macOS Minecraft 启动器

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](https://www.apple.com/macos/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](./LICENSE)
[![Status](https://img.shields.io/badge/status-Beta-orange)](./CHANGELOG.md)

SL（应用内名 **qwq**）是一个使用 **Swift + SwiftUI** 原生编写的 macOS Minecraft 启动器。启动核心为从零实现的 Swift 原生代码（`qwq/SLCore`），部分算法（如离线 UUID 生成）移植自 PCL2，均在源码注释中标注了来源。

> ⚠️ **外置登录（Yggdrasil）为桩实现**（运行期按离线账号处理，见[功能状态](#功能状态)）。
> 欢迎提 Issue 和 PR。

## 功能状态

### ✅ 已实现

- **游戏启动**：离线账号启动，支持启动前完整性检查与缺失文件自动补全（参考 PCL2 `DlClientFix` 思路的原生实现）
- **版本安装**：原版 / Fabric / Forge / NeoForge / Quilt 版本下载与安装，加载器支持检测（逐加载器流式检测 + 按加载器粒度缓存）
- **Java 管理**：本机 Java 扫描、按版本要求自动选择、架构兼容性检查（含 Rosetta 场景 JVM 参数过滤）、Java 下载
- **Mod 下载**：内置 Modrinth 全量离线目录（约 12MB gzip，随包分发），支持分类浏览、搜索、中文项目名翻译
- **模组包**：Modrinth 模组包下载与安装
- **皮肤**：离线皮肤加载、头像裁剪、皮肤资源包应用
- **MSA 微软账号登录**：**已实现**。默认借用 PrismLauncher（开源）公开注册的
  client id（public client，无 secret），走 OAuth 2.0 设备码流程；
  可在「设置 → 账号」里换成自己注册的 Azure 应用 id（详见下方「身份与合规」）：浏览器打开 microsoft.com/link 输入设备码 → 轮询拿
  MSA 令牌 → 补齐 XBL→XSTS→MC 全链路（见 `qwq/SLCore/Account/MicrosoftAuthService.swift`）。
  登录成功持久化账号（`AccountManager`），启动前自动刷新令牌链
- **其他**：崩溃自捕获（写入 `~/Library/Logs/SL_crash.log`）、游戏日志实时管道（跨块 UTF-8 安全解码）、下载缓存治理（内存 LRU + 磁盘两级）

### 🚧 未完成（计划中）

- **外置登录（authlib-injector / Yggdrasil）**：桩实现
- **主题系统**：仅基础框架
- **多 Minecraft 目录管理**：仅默认目录

## 构建要求

- macOS 13.0+
- Xcode 26.3（工程以此为创建与验证环境；Swift 语言模式 5.0，`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）
- 依赖通过 Swift Package Manager 自动解析：[SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON)、[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)

## 构建

```bash
git clone https://github.com/asdfasdfasdfasdfasdf111/SL.git
cd SL
open qwq.xcodeproj   # Xcode 中 ⌘R 直接运行
```

或命令行：

```bash
xcodebuild -project qwq.xcodeproj -scheme qwq -configuration Debug build
```

## 项目结构

```
SL/
├── qwq/                    # 应用源码
│   ├── App/                # 入口与 App 级组件
│   ├── Core/               # 跨功能领域抽象（Download 引擎门面 / Events）
│   ├── Features/           # 按功能划分（Launch / Game / Download / ModBrowser / Translation / Skin / Java / Settings / Theme）
│   ├── SLCore/            # 原生重写的启动核心（下载 / 安装 / 启动 / 加载器）
│   ├── Models/  UI/
│   └── Assets.xcassets
├── qwqTests/               # 单元测试（XCTest target，目录自动同步）
├── docs/                   # 架构与重构文档
├── scripts/                # 辅助脚本（Modrinth 目录爬虫等）
├── README.md
├── HANDOVER.md             # 交接文档（接手者先读这个）
├── ARCHITECTURE.md         # 当前真实存在的架构与分层
├── CHANGELOG.md            # 更新日志（2026-10 起冻结，变更看 git log）
└── LICENSE
```

## 文档导航

| 想知道什么 | 看哪份 |
|---|---|
| **怎么上手、怎么验证、坑在哪** | **[`HANDOVER.md`](./HANDOVER.md)** ← 接手者从这里开始 |
| 这是什么应用、功能状态 | `README.md`（本文） |
| 当前真实存在的架构与分层 | `ARCHITECTURE.md` |
| 重构的历史计划（多为已成历史） | `REFACTOR_PLAN.md` |
| 模块完成度盘点（部分作废，见文首警示） | `docs/archive/MODULE-INVENTORY.md` |
| 测试怎么跑、覆盖了什么 | `qwqTests/TESTING.md` |
| 每一轮改了什么、为什么 | `CHANGELOG.md`（2026-10 起冻结，变更看 git log） |
| 哪些是桩实现 | `qwq/SLCore/STUBS_AUDIT.md` |
| 第三方引用逐条清单（移植算法/来源/依据） | `docs/THIRD-PARTY-NOTICES.md` |

## 致谢与引用说明

- **[PCL2（Plain Craft Launcher 2）](https://github.com/Hex-Dragon/PCL2)** by 龙腾猫跃：本项目参考了其启动流程、完整性补全（`DlClientFix`）、离线 UUID 算法（`McLoginLegacyUuid`）等实现思路，少量算法级移植已在源码注释中逐处标注。PCL2 源码库许可为保留所有权利、允许思路参考与少量引用（见其仓库 `LICENCE`），本项目未整段复制其代码。
- **PCLMac**：项目早期参考过其架构，启动核心现为 Swift 原生重写，兼容层见 `qwq/SLCore/SLLaunchBridge.swift`。
- **[Modrinth](https://modrinth.com)**：Mod 元数据来源，离线目录由 `scripts/crawl_modrinth.py` 生成。

## 身份与合规

> 以下为**分发前必须知悉**的合规事项。作为非商业个人项目可能足够，但正式对外分发请逐条核验。

- **微软登录借用第三方公开 client id**（设备码流程，public client 无 secret，见 `MicrosoftAuthService.swift`）。**这不是假设的风险，已经发生过一次**：原先借用的微软官方 Minecraft Launcher id `00000000402b5328` 被微软下线，设备码端点直接返回 `AADSTS700016 应用不存在`（2026-10-05 实测），登录链路整条失效。现改为借用 PrismLauncher 公开注册的 id 作为默认值 —— 同样随时可能失效。**已做的兜底**：client id 提为可配置（存储键 `UDK.microsoftClientID`，`MicrosoftAuthService.clientID` 读取），「设置 → 账号」页可填自己注册的 Azure 应用 id 并一键「验证配置」，错误文案会直接指向该页。**建议**：正式分发前注册自有 Azure AD 应用（device code 免费、无需 secret）替换默认值。
- **GPL-3.0 与本项目的移植**：项目整体为 [GPL-3.0](./LICENSE)。对 PCL2 的移植均为**思路级/少量引用级**（未整段复制），已在源码注释与 `docs/THIRD-PARTY-NOTICES.md` 中逐条给出依据；如被质疑，以该清单为准自查。
- **Modrinth 数据再分发**：内置 12MB 离线目录由 Modrinth API 生成，随包分发。请核阅 Modrinth 当前 API 条款对「项目元数据离线再分发」的要求（本项目保留源站信息，未二次改动内容）。
- **macOS 分发**：签名与公证（notarization）未在 README 提供现成命令——因为本项目**尚未配置分发签名身份**。正式对外分发前需：① 注册 Apple Developer 并为构建产物签名；② 用 `xcrun notarytool submit` 提交公证；③ 把公证书 stapled 到 App。未公证的 App 若未右键打开会被 Gatekeeper 拦截——是否配置签名身份由项目所有者决定，本文仅如实记录现状。

## 许可证

本项目以 [GPL-3.0](./LICENSE) 授权。引用的第三方库（SwiftyJSON、ZIPFoundation）遵循各自的开源许可证。

## 赞助

项目目前处于早期开发阶段，**赞助完全自愿、且不建议在功能完善前赞助**。若你仍然愿意支持开发，可在应用内「赞助」页查看方式。
