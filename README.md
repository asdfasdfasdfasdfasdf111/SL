# SL — macOS Minecraft 启动器

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](https://www.apple.com/macos/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](./LICENSE)
[![Status](https://img.shields.io/badge/status-Beta%200.1.10-orange)](./CHANGELOG.md)

SL（应用内名 **qwq**）是一个使用 **Swift + SwiftUI** 原生编写的 macOS Minecraft 启动器。启动核心为从零实现的 Swift 原生代码（`qwq/PCLCore`），部分算法（如离线 UUID 生成）移植自 PCL2，均在源码注释中标注了来源。

> ⚠️ **项目处于早期 Beta 阶段**（v0.1.x），部分功能尚未完成，详见下方[功能状态](#功能状态)。欢迎提 Issue 和 PR，但请勿用于日常主力启动。

## 功能状态

### ✅ 已实现

- **游戏启动**：离线账号启动，支持启动前完整性检查与缺失文件自动补全（参考 PCL2 `DlClientFix` 思路的原生实现）
- **版本安装**：原版 / Fabric / Forge / NeoForge / Quilt 版本下载与安装，加载器支持检测（逐加载器流式检测 + 按加载器粒度缓存）
- **Java 管理**：本机 Java 扫描、按版本要求自动选择、架构兼容性检查（含 Rosetta 场景 JVM 参数过滤）、Java 下载
- **Mod 下载**：内置 Modrinth 全量离线目录（约 12MB gzip，随包分发），支持分类浏览、搜索、中文项目名翻译
- **模组包**：Modrinth 模组包下载与安装
- **皮肤**：离线皮肤加载、头像裁剪、皮肤资源包应用
- **其他**：崩溃自捕获（写入 `~/Library/Logs/qwq_crash.log`）、游戏日志实时管道（跨块 UTF-8 安全解码）、下载缓存治理（内存 LRU + 磁盘两级）

### 🚧 未完成（计划中）

- **微软账号登录**：当前为桩实现（`PCLStubs.swift` 中 `AnyAccount.microsoft` 退化为离线账号）
- **外置登录（authlib-injector / Yggdrasil）**：桩实现
- **主题系统**：仅基础框架
- **多 Minecraft 目录管理**：仅默认目录

## 构建要求

- macOS 13.0+
- Xcode 15+（项目使用 Xcode 26.3 创建）
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
│   ├── Features/           # 按功能划分（Launch / Game / Download / ModBrowser / Translation / Skin / Java / Settings）
│   ├── PCLCore/            # 原生重写的启动核心（下载 / 安装 / 启动 / 加载器）
│   ├── Models/  Services/  UI/
│   └── Assets.xcassets
├── scripts/                # 辅助脚本（Modrinth 目录爬虫等）
├── CHANGELOG.md            # 更新日志
└── LICENSE
```

## 致谢与引用说明

- **[PCL2（Plain Craft Launcher 2）](https://github.com/Hex-Dragon/PCL2)** by 龙腾猫跃：本项目参考了其启动流程、完整性补全（`DlClientFix`）、离线 UUID 算法（`McLoginLegacyUuid`）等实现思路，少量算法级移植已在源码注释中逐处标注。PCL2 源码库许可为保留所有权利、允许思路参考与少量引用（见其仓库 `LICENCE`），本项目未整段复制其代码。
- **PCLMac**：项目早期参考过其架构，启动核心现为 Swift 原生重写，兼容层见 `qwq/PCLCore/PCLLaunchBridge.swift`。
- **[Modrinth](https://modrinth.com)**：Mod 元数据来源，离线目录由 `scripts/crawl_modrinth.py` 生成。

## 许可证

本项目以 [GPL-3.0](./LICENSE) 授权。引用的第三方库（SwiftyJSON、ZIPFoundation）遵循各自的开源许可证。

## 赞助

项目目前处于早期开发阶段，**赞助完全自愿、且不建议在功能完善前赞助**。若你仍然愿意支持开发，可在应用内「赞助」页查看方式。
