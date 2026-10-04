# 第三方引用清单（THIRD-PARTY NOTICES）

> 用途：逐条列出项目对第三方代码/数据的**引用性质与依据**，用于（1）说服自己与读者
> 「哪些是思路借鉴、哪些是复制」；（2）分发前若被质疑，以本文为准自查。
> 本项目整体为 **GPL-3.0**（见 `LICENSE`）。列出的引用均以「思路级 / 少量引用级」为界，
> 未整段复制任何第三方代码；各引用点在源码注释中已标注，行号类引用遵循
> `OfflineAccount.swift` 头注释约定「文件 + 符号/场景，不写行号」。

## 一、PCL2（Plain Craft Launcher 2，龙腾猫跃）

> 上游许可：保留所有权利，允许**思路参考与少量引用**（见其仓库 `LICENCE`）。
> 本项目的移植均遵守该边界：只借鉴算法语义，实现全部为 Swift 原生重写。

| # | 引用内容 | 落点（文件 / 符号） | 性质与依据 |
|---|---|---|---|
| 1 | 离线 UUID 算法三件套（名字长度 hex + GetHash hex 拼接，强制 version=3 / variant=9，保证任意用户名产生合法 RFC 4122 UUID） | `qwq/SLCore/Account/OfflineAccount.swift`：`legacyUuidHex(for:)` / `formatUuid(_:)` / `OfflineAccount.init` | **算法级移植**，源码注释逐行标注对应 PCL2 `ModLaunch.vb McLoginLegacyUuid`。语义移植、Swift 重写，未复制 VB.NET 代码 |
| 2 | 离线用户名校验语义（1.18+ 服务端拒绝非 `[0-9A-Za-z_]`） | `qwq/Features/Skin/OfflineUsernameValidator.swift`：`validate` / `hint(for:)` | **思路级**。PCL2 `HintChinese` 语义（哪些字符被服务端拒绝），规则独立实现 |
| 3 | 离线皮肤资源包（注入 options.txt 的 resourcePacks，追加到末尾 = 最高优先级；vanilla 打底） | `qwq/Features/Skin/SkinResourcePackApplier.swift`：`install` / `beginInstall` | **思路级**。PCL2 资源包注入的排序语义，打包/注入为 Swift 原生实现 |
| 4 | 启动前完整性检查与缺失文件自动补全（DlClientFix 思路） | `qwq/SLCore/SLLaunchBridge.swift` 与依赖链（启动前校验） | **思路级**。只借鉴"完整性检查+补全"的流程思路，机制为原生实现 |

## 二、Modrinth（API 数据）

| 引用内容 | 落点 | 说明 |
|---|---|---|
| Modrinth 项目元数据离线目录（mod/resourcepack/shader/modpack 全量条目，约 12MB gzip） | `qwq/modrinth_catalog.json.gz`；生成器 `scripts/crawl_modrinth.py`；消费方 `qwq/Features/ModBrowser/LocalModCatalog.swift` | 随包分发（`Bundle.main` 读取）。保留源站信息、未二次改动内容。**请在分发前核阅 Modrinth API 当前条款**对离线再分发的要求 |

## 三、第三方依赖库（各依其自身许可证）

| 库 | 用途 | 许可证 |
|---|---|---|
| SwiftyJSON | JSON 解析（网络响应） | MIT |
| ZIPFoundation | jar/zip 归档只读（`ArchiveUtil`）与归档操作 | MIT |

依赖声明见 Xcode 工程 Swift Package 解析（`qwq.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`）。

## 四、微软登录身份（非代码引用，但属外部依赖）

| 依赖 | 当前状态 | 风险 |
|---|---|---|
| 微软公开 client id `00000000402b5328`（`MicrosoftAuthService.swift` `MicrosoftAuthConstants.clientID`） | 借用第三方应用身份（设备码流程，public client 无 secret） | 微软收紧该 client 第三方用途时，登录链路**同时失效、无降级路径**。计划：注册自有 Azure AD 应用后提为可配置常量并保留 fallback |

## 五、更名/归档记录

- 本清单文档历史：2026-10-05 由 README「致谢与引用说明」不足部分独立成文；README 保留摘要，明细以此为准。
- 若新增任何第三方移植/引用，**必须在此追加一行**（含落点与性质），并在源码注释同步标注。